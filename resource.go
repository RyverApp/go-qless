package qless

import "github.com/gomodule/redigo/redis"

type Resource interface {
	Exists() bool
}

type resource struct {
	c    *Client
	name string
}

func (r *resource) Max() (int64, error) {
	return redis.Int64(r.c.Do("resource.get", timestamp(), r.name))
}

func (r *resource) SetMax(v int) error {
	_, err := r.c.Do("resource.set", timestamp(), r.name, v)
	return err
}

func (r *resource) Delete() error {
	_, err := r.c.Do("resource.unset", timestamp(), r.name)
	return err
}

func (r *resource) Exists() (bool, error) {
	return Bool(r.c.Do("resource.exists", timestamp(), r.name))
}

func (r *resource) LockCount() (int64, error) {
	return redis.Int64(r.c.Do("resource.lock_count", timestamp(), r.name))
}

func (r *resource) Locks() ([]string, error) {
	b, err := redis.Bytes(r.c.Do("resource.locks", timestamp(), r.name))
	if err != nil {
		return nil, err
	}
	var j StringSlice
	err = unmarshal(b, &j)
	return j, err
}

func (r *resource) PendingCount() (int64, error) {
	return redis.Int64(r.c.Do("resource.pending_count", timestamp(), r.name))
}

func (r *resource) Pending() ([]string, error) {
	b, err := redis.Bytes(r.c.Do("resource.pending", timestamp(), r.name))
	if err != nil {
		return nil, err
	}
	var j StringSlice
	err = unmarshal(b, &j)
	return j, err
}
