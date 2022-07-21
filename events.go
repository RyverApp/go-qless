package qless

import (
	"sync"

	"github.com/gomodule/redigo/redis"
)

type Events struct {
	pool *redis.Pool

	// locks following
	l           sync.Mutex
	c           *redis.PubSubConn
	subscribers []chan<- interface{}
}

var channels = []interface{}{"ql:log", "ql:canceled", "ql:completed", "ql:failed", "ql:popped", "ql:stalled", "ql:put", "ql:track", "ql:untrack"}

func (e *Events) Subscribe(ch chan<- interface{}) error {
	e.l.Lock()
	defer e.l.Unlock()

	e.subscribers = append(e.subscribers, ch)

	if e.c == nil {
		return e.start()
	}
	return nil
}

func (e *Events) Unsubscribe(ch chan<- interface{}) {
	e.l.Lock()
	defer e.l.Unlock()

	for i := 0; i < len(e.subscribers); i++ {
		if e.subscribers[i] == ch {
			close(ch)
			l := len(e.subscribers) - 1
			e.subscribers[i] = e.subscribers[l]
			e.subscribers[l] = nil
			e.subscribers = e.subscribers[:l]
		}
	}

	if len(e.subscribers) == 0 {
		e.subscribers = nil
	}
}

func (e *Events) start() error {
	psc := redis.PubSubConn{Conn: e.pool.Get()}
	if err := psc.Subscribe(channels...); err != nil {
		psc.Conn.Close()
		return err
	}

	e.c = &psc
	go e.run(psc)

	return nil
}

func (e *Events) Close() {
	e.l.Lock()
	defer e.l.Unlock()

	if e.subscribers != nil {
		for _, ch := range e.subscribers {
			close(ch)
		}
		e.subscribers = nil
	}

	if e.c != nil {
		e.c.Unsubscribe()
		e.c.Conn.Close()
		e.c = nil
	}
}

func (e *Events) run(psc redis.PubSubConn) {
	defer func() {
		e.Close()
	}()

	running := true
	for running {
		val := psc.Receive()
		if _, ok := val.(error); ok {
			running = false
		}

		e.l.Lock()
		sub := e.subscribers
		oldLen := len(sub)
		for i := 0; i < len(sub); i++ {
			ch := sub[i]
			select {
			case ch <- val:
			default:
				// blocking channels are removed
				close(ch)
				e := len(sub) - 1
				sub[i] = sub[e]
				sub[e] = nil
				sub = sub[:e]
			}
		}
		switch len(sub) {
		case 0:
			running = false
			e.subscribers = nil
		case oldLen: // do nothing
		default:
			e.subscribers = sub
		}
		e.l.Unlock()
	}
}
