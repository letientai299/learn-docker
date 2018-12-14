<!-- vim: set spell : -->

# Stop Script Quickly in Docker

## Context

As I'm writing more and more wiki page on both Gitlab and Github, I've started
to build [gollum-reload](https://github.com/letientai299/gollum-reload), a
docker image to run Gollum and Guard that will monitor our wiki folder and
reload the web browser on file change.

Since gollum-reload is basically a docker image, during building it, I need to
rebuild, stop and start it a lot. Build image and start new container it very
fast. But stop the running container is painfully slow. I've added a [dirty work
around](https://github.com/letientai299/gollum-reload/blob/f464b73b57c51fc9da2d794017b0c1dc9f010fdd/scripts/stop.sh)
to make stopping the container faster. But end users of gollum-reload image won't
be able to use it easily, unless they embedded my project into their wiki.
So, there's the need to fix that problem properly.

For the rest of this post, we will use another image to demonstrate and explain
several approaches.

## Problem

`docker stop` command can takes quite long time to stop a container that running a
script.

## Example

Let's say we want to have a customized redis container that need to do something
before starting redis-server.

Here's our `Dockerfile`

```
FROM redis:alpine
COPY ./runner.sh /workspace/runner.sh
WORKDIR /workspace

CMD ["./runner.sh"]
```

And here's the `runner.sh`

```sh
#!/bin/sh

# do other stuff before running redis server ...

# Start redis-server in the foreground, otherwise the script will exit,
# and docker will kill everything else, include redis-server
redis-server
```

Pretty simple! Now, let's build the image

```sh
$ docker build . -t customized-redis
```

And run it, without detaching to see redis log

```sh
$ docker run --rm --name slow-dying-redis customized-redis
```

**Note**

- Since this is just a throw away container, we use `--rm` to remove it once
  it's stopped.

- It's a best practice to give giving the container a proper name (actually,
  everything should have a proper name). So that we quickly recognize what is it
  used for, and we can write other script that target to exactly that container.

Now, try stopping that container with the usual `docker stop`, also timing how
long until it done:

```sh
$ time docker stop slow-dying-redis
slow-dying-redis
docker stop slow-dying-redis 0.01s user 0.02s system 0% cpu 10.461 total
```

I don't know about you, but to me, 10s to stop the containers is pretty long.

## Why docker stop take that much time?

`docker stop` attempts [to be nice](https://turnoff.us/geek/dont-sigkill/). It
first sends`SIGTERM`, expect our applications to catch the signal, clean thing
up and kill themselves. Most application will catch that and stop nicely.

In this case, however, `redis-sever` is started within our script `runner.sh`,
which is ran by `/bin/sh`. Check that using `docker stop`

```sh
$ docker top slow-dying-redis

UID   PID     PPID   C  STIME   TTY  TIME       CMD
root  19667   19633  0  18:37   ?    00:00:00   /bin/sh ./runner.sh
root  19716   19667  0  18:37   ?    00:00:00   redis-server
```

The process that will handle `SIGTERM` is actually `/bin/sh`. It won't forward
the signal to child process. That's why `redis-server` won't stop.

And after some time ([default timeout is 10s](https://docs.docker.com/engine/reference/commandline/stop/)),
docker will forcefully kill the application by sending `SIGKILL`. `/bin/sh` and all its
child will be killed.

## Work around

If our applications don't need cleaning up on shutdown, we can just use `docker kill`.

But for some application, like database container that save to data to mounted
volume, graceful shutdown is a must.

## Make docker stop work properly

There's 2 ways, depends on your actual situation

### Script that spawn only one application

We can use `exec` to run `redis-server`, like:

```sh
#!/bin/sh
# do other stuff before running redis server ...

# Start redis-server and replace this shell
exec redis-server
```

`exec` will [replaces the current program in the current
process](https://stackoverflow.com/a/18351547/3869533), so `redis-server` will
completely in control for the process that starts it.

```sh
$ docker top slow-dying-redis

UID   PID     PPID   C  STIME   TTY  TIME       CMD
root  20270   20244  0  18:33   ?    00:00:00   redis-server
```

After that, `SIGTERM` from `docker stop` will go into `redis-server` and is handled
nicely.

```
1:signal-handler (1544783816) Received SIGTERM scheduling shutdown...
1:M 14 Dec 2018 10:36:56.647 # User requested shutdown...
1:M 14 Dec 2018 10:36:56.647 * Saving the final RDB snapshot before exiting.
1:M 14 Dec 2018 10:36:56.652 * DB saved on disk
1:M 14 Dec 2018 10:36:56.652 # Redis is now ready to exit, bye bye...
```

### Script that will start multiple processes

Unix have a [trap](http://man7.org/linux/man-pages/man1/trap.1p.html) function
that can be used to catches and handle a signal using some commands.

#### Trap example

Create a file named `trap_example.sh` with following content

```sh
#!/bin/sh

trap "echo I won\'t stop with SIGTERM" TERM
trap "echo I won\'t stop with SIGINT" INT

counter="1"
while true; do
  # print the counter every 1 second
  sleep 1
  echo $counter
  counter=$((counter + 1))
done
```

Try run it and then stop it, you will find that it won't top on Ctrl-C, which
will send `SIGINT`, because we already handle that.

```
1
^CI won't stop with SIGINT
2
3
4
```

It also won't stop on `SIGNTERM`, which is sent from `kill` or `pkill` by
default:

```sh
$ pkill trap-example.sh
```

So, how to kill it then? You will need to use `SIGKILL`, which is, by design,
can't be trapped by the application. All application receive that signal will be
... killed. Use following command to kill it:

```sh
$ pkill -9 trap-example.sh
```

#### Handling SIGTERM properly

If we add trap handling naively, like this:

```sh
#!/bin/sh

# Holding redis pid to be used for killing it later
redis_pid=0

shutdown(){
  # kill redis with SIGTERM
  kill $redis_pid
  # wait for redis to finish it shutdown
  wait $redis_pid
  exit 143 # 128 + 15 -- SIGTERM
}

trap 'shutdown' TERM

redis-server
redis_pid=$!
```

It won't work, because redis-server run in the foreground and doesn't return
control to the script. Thus, `sh` can't execute it's trap handler. We need to
run redis in background instead.

Our final implementation:

```sh
#!/bin/sh

# Holding redis pid to be used for killing it later
redis_pid=0

shutdown(){
  # kill redis with SIGTERM
  kill $redis_pid
  # wait for redis to finish it shutdown
  wait $redis_pid
  exit 143 # 128 + 15 -- SIGTERM
}

trap 'shutdown' TERM

# run redis in background
redis-server &
redis_pid=$!

# and wait for it to finish
wait $redis_pid
```

Now, `docker stop` should be quick as usual.

## Conclusion

As usual, we learn many thing as we keep try to improve what we have. I've learn
some new things about Unix shell and I hope that this post also help you so.
