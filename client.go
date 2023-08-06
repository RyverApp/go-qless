package qless

import (
	_ "embed"
	"errors"
	"fmt"
	"strconv"
	"time"

	"github.com/gomodule/redigo/redis"
)

//go:embed qless.lua
var qlessLua string

type TaggedReply struct {
	Total int
	Jobs  StringSlice
}

type Client struct {
	pool   *redis.Pool
	own    bool
	events *Events
	lua    *redis.Script
}

type dialOptions struct {
	db              int
	maxIdle         int
	idleTimeout     time.Duration
	maxActive       int
	minPingInterval time.Duration
	connectTimeout  time.Duration
}

type dialOptionFn func(o *dialOptions)

// DialDatabase specifies the database to select when establishing a new
// connection
func DialDatabase(v int) dialOptionFn {
	return func(o *dialOptions) {
		o.db = v
	}
}

// DialMaxIdle specifies the maximum number of idle connections in the pool
func DialMaxIdle(v int) dialOptionFn {
	return func(o *dialOptions) {
		o.maxIdle = v
	}
}

func DialIdleTimeout(v time.Duration) dialOptionFn {
	return func(o *dialOptions) {
		o.idleTimeout = v
	}
}

func DialMaxActive(v int) dialOptionFn {
	return func(o *dialOptions) {
		o.maxActive = v
	}
}

func DialMinPingInterval(v time.Duration) dialOptionFn {
	return func(o *dialOptions) {
		o.minPingInterval = v
	}
}

func DialConnectTimeout(v time.Duration) dialOptionFn {
	return func(o *dialOptions) {
		o.connectTimeout = v
	}
}

func NewClient(pool *redis.Pool) *Client {
	return &Client{
		pool: pool,
		lua:  redis.NewScript(0, qlessLua),
	}
}

func Dial(host, port string, opts ...dialOptionFn) (*Client, error) {
	opt := &dialOptions{connectTimeout: time.Second, minPingInterval: time.Minute, idleTimeout: 30 * time.Minute}
	for _, fn := range opts {
		fn(opt)
	}

	addr := fmt.Sprintf("%s:%s", host, port)

	pool := &redis.Pool{
		MaxIdle:     opt.maxIdle,
		MaxActive:   opt.maxActive,
		IdleTimeout: opt.idleTimeout,

		Dial: func() (redis.Conn, error) {
			cn, err := redis.Dial("tcp", addr,
				redis.DialConnectTimeout(opt.connectTimeout),
				redis.DialDatabase(opt.db),
			)
			if err != nil {
				return nil, err
			}
			return cn, nil
		},

		TestOnBorrow: func(c redis.Conn, t time.Time) error {
			if time.Since(t) < opt.minPingInterval {
				return nil
			}

			_, err := c.Do("PING")
			return err
		},
	}

	return &Client{
		pool: pool,
		own:  true,
		lua:  redis.NewScript(0, qlessLua),
	}, nil
}

func (c *Client) Close() {
	if c.events != nil {
		c.events.Close()
	}

	if c.own && c.pool != nil {
		c.pool.Close()
		c.pool = nil
	}
}

func (c *Client) Events() *Events {
	if c.events != nil {
		return c.events
	}
	c.events = &Events{pool: c.pool}
	return c.events
}

func scriptReply(reply interface{}, err error) (interface{}, error) {
	return reply, parseError(err)
}

func (c *Client) Do(args ...interface{}) (interface{}, error) {
	cn := c.pool.Get()
	defer cn.Close()
	return scriptReply(c.lua.Do(cn, args...))
}

func (c *Client) Queue(name string) Queue {
	return &queue{name: name, c: c}
}

func (c *Client) Queues() (queues []Queue, err error) {
	args := []interface{}{"queues", timestamp()}
	data, err := redis.Bytes(c.Do(args...))
	if err != nil {
		return nil, err
	}

	var infos []QueueInfo
	err = unmarshal(data, &infos)
	if err != nil {
		return nil, err
	}

	queues = make([]Queue, len(infos))
	for i, info := range infos {
		queues[i] = &queue{name: info.Name, info: info, c: c}
	}
	return queues, err
}

func (c *Client) queueInfo(name string, info *QueueInfo) error {
	args := []interface{}{"queues", timestamp(), name}
	data, err := redis.Bytes(c.Do(args...))
	if err != nil {
		return err
	}

	return unmarshal(data, info)
}

// Track the jid
func (c *Client) Track(jid string) (bool, error) {
	return Bool(c.Do("track", timestamp(), "track", jid, ""))
}

// Untrack the jid
func (c *Client) Untrack(jid string) (bool, error) {
	return Bool(c.Do("track", timestamp(), 0, "untrack", jid))
}

// Returns all the tracked jobs
func (c *Client) Tracked() (string, error) {
	return redis.String(c.Do("track", timestamp()))
}

func (c *Client) Get(jid string) (interface{}, error) {
	job, err := c.GetJob(jid)
	if err == redis.ErrNil {
		rjob, err := c.GetRecurringJob(jid)
		return rjob, err
	}
	return job, err
}

func (c *Client) GetJob(jid string) (Job, error) {
	data, err := redis.Bytes(c.Do("get", timestamp(), jid))
	if err != nil {
		return nil, err
	}

	var d jobData
	err = unmarshal(data, &d)
	if err != nil {
		return nil, err
	}
	return &job{d: &d, c: c}, err
}

func (c *Client) GetRecurringJob(jid string) (*RecurringJob, error) {
	data, err := redis.Bytes(c.Do("recur", timestamp(), "get", jid))
	if err != nil {
		return nil, err
	}

	job := &RecurringJob{c: c}
	err = unmarshal(data, job)
	if err != nil {
		return nil, err
	}
	return job, err
}

func (c *Client) Completed(start, count int) ([]string, error) {
	reply, err := redis.Values(c.Do("jobs", timestamp(), "complete"))
	if err != nil {
		return nil, err
	}

	ret := []string{}
	for _, val := range reply {
		s, _ := redis.String(val, err)
		ret = append(ret, s)
	}
	return ret, err
}

func (c *Client) Tagged(tag string, start, count int) (*TaggedReply, error) {
	data, err := redis.Bytes(c.Do("tag", timestamp(), "get", tag, start, count))
	if err != nil {
		return nil, err
	}

	t := &TaggedReply{}
	err = unmarshal(data, t)
	return t, err
}

func (c *Client) GetConfig(option string) (string, error) {
	reply, err := c.Do("config.get", timestamp(), option)
	if err != nil {
		return "", err
	}

	var contentStr string
	switch reply.(type) {
	case []uint8:
		contentStr, err = redis.String(reply, nil)
	case int64:
		var contentInt64 int64
		contentInt64, err = redis.Int64(reply, nil)
		if err == nil {
			contentStr = strconv.Itoa(int(contentInt64))
		}
	default:
		err = errors.New("The redis return type is not []uint8 or int64")
	}
	if err != nil {
		return "", err
	}

	return contentStr, err
}

func (c *Client) SetConfig(option string, value interface{}) {
	reply, err := c.Do("config.set", timestamp(), option, value)
	if err != nil {
		fmt.Println("setconfig, c.Do fail. interface:", reply, " err:", err)
	}
}

func (c *Client) UnsetConfig(option string) {
	c.Do("config.unset", timestamp(), option)
}
