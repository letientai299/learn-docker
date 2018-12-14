<!-- vim: set spell : -->

# Stop Script Quickly in Docker

## Problem

`docker stop` command takes quite long time to stop a container that running a
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

## Reason

`docker stop` attempt to do a [graceful shutdown](https://turnoff.us/geek/dont-sigkill/),
by sending `SIGTERM`, expect our applications to catch the signal, clean thing
up and kill themselves. Since, our "app" is just a simple script that doesn't
handle any signal, docker will send `SIGKILL` after timeout
([default value is 10s](https://docs.docker.com/engine/reference/commandline/stop/))

If our apps don't need cleaning up on shutdown, we can just use `docker kill`,
but there's a better way.

## Handling SIGTERM in script
