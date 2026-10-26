# How to run background jobs

You will enqueue work from an endpoint and process it in a separate worker process. Azu does not include a job queue; [JoobQ](https://github.com/azutoolkit/joobq) is a separate shard that keeps jobs in Redis, and `azu new` can set it up for you (`azu generate joobq`, `azu jobs:worker`).

The snippets need the `joobq` shard, which the docs check does not install, so they are marked as fragments. They were moved here from the old README and not re-run against a current JoobQ release; check JoobQ's own documentation for the exact API of the version you install.

## Add JoobQ

```yaml
dependencies:
  azu:
    github: azutoolkit/azu
    version: ~> 0.5.119
  joobq:
    github: azutoolkit/joobq
```

## Define a job and a queue

<!-- skip -->
```crystal
# src/jobs/email_job.cr
struct EmailJob
  include JoobQ::Job

  @queue = "default"
  @retries = 3
  @expires = 1.days.total_seconds.to_i

  def initialize(@email_address : String, @subject : String)
  end

  def perform
    Log.info { "Sending #{@subject} to #{@email_address}" }
  end
end

# src/jobs.cr
JoobQ.configure do
  queue "default", 2, EmailJob
end
```

## Enqueue from an endpoint

<!-- skip -->
```crystal
struct CreateUserEndpoint
  include Azu::Endpoint(UserRequest, UserResponse)

  post "/api/users"

  def call : UserResponse
    user = UserService.create_user(user_request)
    EmailJob.enqueue(email_address: user.email, subject: "Welcome!")
    status 201
    UserResponse.new(user)
  end
end

# Delayed and recurring
EmailJob.enqueue_at(time: 2.hours.from_now, email_address: "user@example.com", subject: "Reminder")
EmailJob.schedule(every: 1.day, email_address: "team@example.com", subject: "Daily digest")
```

## Run the worker

<!-- skip -->
```crystal
# worker.cr
require "./src/jobs"

JoobQ.forge
sleep
```

Run the web server and the worker as two processes (`crystal run server.cr`, `crystal run worker.cr`), or use `azu jobs:worker` in a generated project.
