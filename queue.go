package qless

import (
	"time"

	"github.com/gomodule/redigo/redis"
)

type Queue interface {
	Name() string
	Info() QueueInfo
	Jobs(state string, start, count int) ([]string, error)
	CancelAll()
	Pause()
	Resume()
	Put(class string, data interface{}, opt ...putOptionFn) (string, error)
	PutOrReplace(class string, jid string, data interface{}, opt ...putOptionFn) (int64, error)
	PopOne() (j Job, err error)
	Pop(count int) ([]Job, error)
	Recur(class string, data interface{}, interval int, opt ...putOptionFn) (string, error)
	Len() (int64, error)
	Stats(time.Time) (*QueueStatistics, error)
}

type queue struct {
	name string
	info QueueInfo
	c    *Client
}

func (q *queue) Name() string {
	return q.name
}

func (q *queue) Info() QueueInfo {
	q.c.queueInfo(q.name, &q.info)
	return q.info
}

func (q *queue) Jobs(state string, start, count int) ([]string, error) {
	reply, err := redis.Values(q.c.Do("jobs", timestamp(), state, q.name))
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

// Cancel all jobs in this queue
func (q *queue) CancelAll() {
	for _, state := range jobStates {
		var jids []string
		for {
			jids, _ = q.Jobs(state, 0, 100)
			for _, jid := range jids {
				j, err := q.c.GetRecurringJob(jid)
				if j != nil && err == nil {
					j.Cancel()
				}
			}

			if len(jids) < 100 {
				break
			}
		}
	}
}

func (q *queue) Pause() {
	q.c.Do("pause", timestamp(), q.name)
}

func (q *queue) Resume() {
	q.c.Do("unpause", timestamp(), q.name)
}

type putData struct {
	jid   string
	delay int
	args  []interface{}
}

func newPutData() putData {
	return putData{}
}

func (p *putData) setOptions(opt []putOptionFn) (err error) {
	for _, fn := range opt {
		fn(p)
	}

	if p.jid == "" {
		p.jid, err = generateUUID()
	}
	return
}

type putOptionFn func(d *putData)

func putOptionNoOp(*putData) {}

func WithJID(v string) putOptionFn {
	return func(p *putData) {
		p.jid = v
	}
}

func WithDelay(v int) putOptionFn {
	return func(p *putData) {
		p.delay = v
	}
}

func WithPriority(v int) putOptionFn {
	return func(p *putData) {
		p.args = append(p.args, "priority", v)
	}
}

func WithRetries(v int) putOptionFn {
	return func(p *putData) {
		p.args = append(p.args, "retries", v)
	}
}

func WithTags(v ...string) putOptionFn {
	if v == nil {
		return putOptionNoOp
	}
	return func(p *putData) {
		p.args = append(p.args, "tags", marshal(v))
	}
}

func WithDepends(v ...string) putOptionFn {
	if v == nil {
		return putOptionNoOp
	}
	return func(p *putData) {
		p.args = append(p.args, "depends", marshal(v))
	}
}

func WithResources(v ...string) putOptionFn {
	if v == nil {
		return putOptionNoOp
	}
	return func(p *putData) {
		p.args = append(p.args, "resources", marshal(v))
	}
}

func WithInterval(v float32) putOptionFn {
	return func(p *putData) {
		p.args = append(p.args, "interval", v)
	}
}

// Put enqueues a job to the named queue
func (q *queue) Put(class string, data interface{}, opt ...putOptionFn) (string, error) {
	pd := newPutData()
	if err := pd.setOptions(opt); err != nil {
		return "", err
	}
	args := []interface{}{"put", timestamp(), "", q.name, pd.jid, class, marshal(data), pd.delay}
	args = append(args, pd.args...)

	return redis.String(q.c.Do(args...))
}

// Put enqueues a job to the named queue
func (q *queue) PutOrReplace(class string, jid string, data interface{}, opt ...putOptionFn) (int64, error) {
	pd := newPutData()
	if err := pd.setOptions(opt); err != nil {
		return -1, err
	}
	args := []interface{}{"put", timestamp(), "", q.name, jid, class, marshal(data), pd.delay}
	args = append(args, pd.args...)
	args = append(args, "replace", 0)

	r, err := q.c.Do(args...)
	if err != nil {
		return -1, err
	}

	if r, ok := r.(int64); ok {
		return r, nil
	}

	return -1, nil
}

func (q *queue) Recur(class string, data interface{}, interval int, opt ...putOptionFn) (string, error) {
	pd := newPutData()
	if err := pd.setOptions(opt); err != nil {
		return "", err
	}

	args := []interface{}{"recur", timestamp(), "on", q.name, pd.jid, class, marshal(data), "interval", interval, pd.delay}
	args = append(args, pd.args...)

	return redis.String(q.c.Do(args...))
}

// Pops a job off the queue.
func (q *queue) PopOne() (j Job, err error) {
	var jobs []Job
	if jobs, err = q.Pop(1); err == nil && len(jobs) == 1 {
		j = jobs[0]
	}
	return
}

// Put a recurring job in this queue
func (q *queue) Pop(count int) ([]Job, error) {
	if count == 0 {
		count = 1
	}

	data, err := redis.Bytes(q.c.Do("pop", timestamp(), q.name, workerNameStr, count))
	if err != nil {
		return nil, err
	}

	if len(data) == 2 {
		return nil, nil
	}

	var jobsData jobDataArray
	err = unmarshal(data, &jobsData)
	if err != nil {
		return nil, err
	}

	jobs := make([]Job, len(jobsData))
	for i, v := range jobsData {
		jobs[i] = &job{d: &v, c: q.c}
	}

	return jobs, nil
}

func (q *queue) Len() (int64, error) {
	reply, err := redis.Int64(q.c.Do("length", timestamp(), q.name))
	if err != nil {
		return -1, err
	}
	return reply, nil
}

func (q *queue) Stats(d time.Time) (*QueueStatistics, error) {
	data, err := redis.Bytes(q.c.Do("stats", timestamp(), q.name, d.Unix()))
	if err != nil {
		return nil, err
	}

	var qs QueueStatistics
	err = unmarshal(data, &qs)
	return &qs, err
}
