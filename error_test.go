package qless

import (
	"testing"

	"github.com/gomodule/redigo/redis"
	"github.com/stretchr/testify/assert"
)

func TestParseError_ReturnsCommandError(t *testing.T) {
	in := redis.Error("ERR Error running script (call to f_986f06a650a32caeb31e59be88090194251ac657): @user_script:883: user_script:883: Heartbeat(): Job given out to another worker: worker-2")
	err := parseError(in)
	if assert.IsType(t, &CommandError{}, err) {
		se := err.(*CommandError)
		assert.Equal(t, "Heartbeat", se.Area)
		assert.Equal(t, "Job given out to another worker: worker-2", se.Message)
	}
}

func TestIsJobLost(t *testing.T) {
	in := redis.Error("ERR Error running script (call to f_986f06a650a32caeb31e59be88090194251ac657): @user_script:883: user_script:883: Heartbeat(): Job given out to another worker: worker-2")
	err := parseError(in)
	assert.True(t, IsJobLost(err))
}

func TestIsNotJobLost(t *testing.T) {
	in := redis.Error("ERR Error running script (call to f_986f06a650a32caeb31e59be88090194251ac657): @user_script:883: user_script:883: Heartbeat(): foo")
	err := parseError(in)
	assert.False(t, IsJobLost(err))
}
