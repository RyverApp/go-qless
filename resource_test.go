package qless

import (
	"testing"

	"github.com/gomodule/redigo/redis"
	"github.com/stretchr/testify/assert"
)

func TestResource_SetMax(t *testing.T) {
	c := newClientFlush()
	r := &resource{c, "test"}
	r.SetMax(10)
	cn := c.pool.Get()
	defer cn.Close()
	m, err := redis.StringMap(cn.Do("HGETALL", "ql:rs:test"))
	assert.NoError(t, err)
	assert.Equal(t, "10", m["max"])
}

func TestResource_MaxIsSet(t *testing.T) {
	c := newClientFlush()
	r := &resource{c, "test"}
	r.SetMax(20)
	m, err := r.Max()
	assert.NoError(t, err)
	assert.EqualValues(t, 20, m)
}

func TestResource_NotExists(t *testing.T) {
	c := newClientFlush()
	r := &resource{c, "test"}
	v, err := r.Exists()
	assert.Error(t, err)
	assert.False(t, v)
}

func TestResource_Exists(t *testing.T) {
	c := newClientFlush()
	r := &resource{c, "test"}
	r.SetMax(10)
	v, err := r.Exists()
	assert.NoError(t, err)
	assert.True(t, v)
}

func TestResource_Delete(t *testing.T) {
	c := newClientFlush()
	r := &resource{c, "test"}
	r.SetMax(10)
	cn := c.pool.Get()
	defer cn.Close()

	v, _ := redis.Bool(cn.Do("EXISTS", "ql:rs:test"))
	assert.True(t, v)

	err := r.Delete()
	assert.NoError(t, err)

	v, _ = redis.Bool(cn.Do("EXISTS", "ql:rs:test"))
	assert.False(t, v)
}

func TestResource_LockCountIsZero(t *testing.T) {
	c := newClientFlush()
	r := &resource{c, "test"}
	r.SetMax(20)
	v, err := r.LockCount()
	assert.NoError(t, err)
	assert.EqualValues(t, 0, v)
}

func TestResource_LocksIsEmpty(t *testing.T) {
	c := newClientFlush()
	r := &resource{c, "test"}
	r.SetMax(20)
	v, err := r.Locks()
	assert.NoError(t, err)
	assert.Empty(t, v)
}

func TestResource_JobLocksResourceAndSecondIsPending(t *testing.T) {
	c := newClientFlush()
	r := &resource{c, "test"}
	r.SetMax(1)

	q := c.Queue("test_queue")
	q.Put("class", "data", WithJID("jid-1"), WithResources("test"))
	q.Put("class", "data", WithJID("jid-2"), WithResources("test"))

	v, err := r.LockCount()
	assert.NoError(t, err)
	assert.EqualValues(t, 1, v)
	j, err := r.Locks()
	assert.NoError(t, err)
	assert.EqualValues(t, []string{"jid-1"}, j)

	v, err = r.PendingCount()
	assert.NoError(t, err)
	assert.EqualValues(t, 1, v)
	j, err = r.Pending()
	assert.NoError(t, err)
	assert.EqualValues(t, []string{"jid-2"}, j)
}
