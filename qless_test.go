package qless

import (
	"os"
	"strconv"
	"testing"
)

var (
	redisHost string
	redisPort string
	redisDB   int
)

func init() {
	redisHost = os.Getenv("REDIS_HOST")
	if redisHost == "" {
		redisHost = "localhost"
	}
	redisPort = os.Getenv("REDIS_PORT")
	if redisPort == "" {
		redisPort = "6379"
	}
	if db := os.Getenv("REDIS_DB"); db != "" {
		if db, err := strconv.Atoi(db); err != nil {
			panic("invalid REDIS_DB")
		} else {
			redisDB = db
		}
	}
}

func newClient() *Client {
	c, err := Dial(redisHost, redisPort, DialDatabase(redisDB))
	if err != nil {
		panic(err.Error())
	}

	return c
}

func newClientFlush() *Client {
	c, err := Dial(redisHost, redisPort, DialDatabase(redisDB))
	if err != nil {
		panic(err.Error())
	}
	cn := c.pool.Get()
	defer cn.Close()

	cn.Do("FLUSHDB")

	return c
}

func flushDB() {
	c := newClient()
	defer c.Close()
	cn := c.pool.Get()
	defer cn.Close()

	cn.Do("FLUSHDB")
}

func TestMain(m *testing.M) {
	flushDB()
	os.Exit(m.Run())
}
