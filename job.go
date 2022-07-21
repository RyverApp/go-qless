package qless

import (
	"time"

	"github.com/gomodule/redigo/redis"
)

var (
	jobStates   = []string{"stalled", "running", "scheduled", "depends", "recurring"}
	finishBytes = []byte(`{"finish":"yes"}`)
)

type Job interface {
	JID() string
	Class() string
	State() string
	Queue() string
	Worker() string
	Tracked() bool
	Priority() int
	Expires() int64
	TTL() int64
	Retries() int
	Remaining() int
	Data() string
	UnmarshalData(v interface{}) error
	Tags() []string
	History() []History
	Failure() *Failure
	Dependents() []string
	Dependencies() []string

	// operations
	Heartbeat() (bool, error)
	Fail(group, message string) (bool, error)
	Complete() (string, error)
	CompleteWithNoData() (string, error)
	HeartbeatWithNoData() (bool, error)
	Cancel()
	Retry(delay int) (int, error)
}

//easyjson:json
type job struct {
	d *jobData
	c *Client
}

func (j *job) JID() string {
	return j.d.JID
}

func (j *job) Class() string {
	return j.d.Class
}

func (j *job) State() string {
	return j.d.State
}

func (j *job) Queue() string {
	return j.d.Queue
}

func (j *job) Worker() string {
	return j.d.Worker
}

func (j *job) Tracked() bool {
	return j.d.Tracked
}

func (j *job) Priority() int {
	return j.d.Priority
}

func (j *job) Expires() int64 {
	return j.d.Expires
}

func (j *job) TTL() int64 {
	return j.d.Expires - time.Now().Unix()
}

func (j *job) Retries() int {
	return j.d.Retries
}

func (j *job) Remaining() int {
	return j.d.Remaining
}

func (j *job) Data() string {
	return j.d.Data
}

func (j *job) UnmarshalData(v interface{}) error {
	return unmarshal([]byte(j.d.Data), v)
}

func (j *job) Tags() []string {
	return j.d.Tags
}

func (j *job) History() []History {
	return j.d.History
}

func (j *job) Failure() *Failure {
	return j.d.Failure
}

func (j *job) Dependents() []string {
	return j.d.Dependents
}

func (j *job) Dependencies() []string {
	return j.d.Dependencies
}

// Move this from it's current queue into another
func (j *job) Move(queueName string) (string, error) {
	return redis.String(j.c.Do("put", timestamp(), queueName, j.d.JID, j.d.Class, []byte(j.d.Data), 0))
}

// Fail this job
func (j *job) Fail(group, message string) (bool, error) {
	return Bool(j.c.Do("fail", timestamp(), j.d.JID, j.d.Worker, group, message, []byte(j.d.Data)))
}

// Heartbeats this job
func (j *job) Heartbeat() (bool, error) {
	return Bool(j.c.Do("heartbeat", timestamp(), j.d.JID, j.d.Worker, []byte(j.d.Data)))
}

// Completes this job
// returns state, error
func (j *job) Complete() (string, error) {
	return redis.String(j.c.Do("complete", timestamp(), j.d.JID, j.d.Worker, j.d.Queue, []byte(j.d.Data)))
}

//for big job, save memory in redis
func (j *job) CompleteWithNoData() (string, error) {
	return redis.String(j.c.Do("complete", timestamp(), j.d.JID, j.d.Worker, j.d.Queue, finishBytes))
}

func (j *job) HeartbeatWithNoData() (bool, error) {
	return Bool(j.c.Do("heartbeat", timestamp(), j.d.JID, j.d.Worker))
}

// Cancels this job
func (j *job) Cancel() {
	j.c.Do("cancel", timestamp(), j.d.JID)
}

// Track this job
func (j *job) Track() (bool, error) {
	return Bool(j.c.Do("track", timestamp(), "track", j.d.JID))
}

// Untrack this job
func (j *job) Untrack() (bool, error) {
	return Bool(j.c.Do("track", timestamp(), "untrack", j.d.JID))
}

func (j *job) AddTags(tags ...interface{}) (string, error) {
	args := []interface{}{"tag", timestamp(), "add", j.d.JID}
	args = append(args, tags...)
	return redis.String(j.c.Do(args...))
}

func (j *job) RemoveTags(tags ...interface{}) (string, error) {
	args := []interface{}{"tag", timestamp(), "remove", j.d.JID}
	args = append(args, tags...)
	return redis.String(j.c.Do(args...))
}

func (j *job) Retry(delay int) (int, error) {
	return redis.Int(j.c.Do("retry", timestamp(), j.d.JID, j.d.Queue, j.d.Worker, delay))
}

func (j *job) Depend(jids ...interface{}) (string, error) {
	args := []interface{}{"depends", timestamp(), j.d.JID, "on"}
	args = append(args, jids...)
	return redis.String(j.c.Do(args...))
}

func (j *job) Undepend(jids ...interface{}) (string, error) {
	args := []interface{}{"depends", timestamp(), j.d.JID, "off"}
	args = append(args, jids...)
	return redis.String(j.c.Do(args...))
}
