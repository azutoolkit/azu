---
description: Enqueue work from an endpoint and process it in a separate worker process.
---

# Run background jobs

Azu has no job queue of its own; [JoobQ](https://github.com/azutoolkit/joobq) is a separate shard that keeps jobs in Redis, so **you need a Redis server** for this guide (Redis is optional for Azu itself). `azu new` includes JoobQ by default, and `--no-joobq` leaves it out.

{% hint style="info" %}
The code below uses the JoobQ 0.4.2 API. Check [JoobQ's README](https://github.com/azutoolkit/joobq) for the version you install.
{% endhint %}

{% stepper %}
{% step %}
#### Add JoobQ

```yaml
dependencies:
  azu:
    github: azutoolkit/azu
    version: ~> 0.5.119
  joobq:
    github: azutoolkit/joobq
```

JoobQ reads its Redis connection from the environment (`REDIS_HOST`, `REDIS_PORT`, `REDIS_POOL_SIZE`, `REDIS_PASS`, see its README).
{% endstep %}

{% step %}
#### Define a job and a queue

A job is a struct that includes `JoobQ::Job`, with the data it needs and a `perform` method. `queue "default", 2, EmailJob` starts two workers for that queue.

<!-- skip -->
```crystal
require "joobq"

struct EmailJob
  include JoobQ::Job

  @queue = "default"
  @retries = 3

  property email_address : String
  property subject : String

  def initialize(@email_address : String, @subject : String)
  end

  def perform
    Log.info { "Sending #{@subject} to #{@email_address}" }
  end
end

JoobQ.configure do |config|
  config.default_queue = "default"
  config.retries = 3

  queue "default", 2, EmailJob
end
```

Generated projects keep the same settings in `config/joobq.<environment>.yml` and load them with `JoobQ.initialize_config_with(:file, path)`; see `src/initializers/joobq.cr` there.
{% endstep %}

{% step %}
#### Enqueue from an endpoint

`enqueue` puts the job on the queue now, `enqueue_at` delays it by a time span, and `schedule(every:)` repeats it.

<!-- skip -->
```crystal
struct WelcomeRequest
  include Azu::Request

  getter email : String

  validate email, match: /@/

  def initialize(@email = "")
  end
end

struct WelcomeResponse
  include Azu::Response

  def render
    %({"queued":true})
  end
end

struct WelcomeEndpoint
  include Azu::Endpoint(WelcomeRequest, WelcomeResponse)

  post "/welcome"

  def call : WelcomeResponse
    EmailJob.enqueue(email_address: welcome_request.email, subject: "Welcome!")
    EmailJob.enqueue_at(2.hours, email_address: welcome_request.email, subject: "Reminder")
    status 202
    content_type "application/json"
    WelcomeResponse.new
  end
end
```

Recurring jobs are set up once, at boot, not per request: `EmailJob.schedule(every: 1.day, email_address: "team@example.com", subject: "Daily digest")`.
{% endstep %}

{% step %}
#### Run the worker

Run the workers in their own process. `JoobQ.forge` starts the queues and then blocks:

<!-- skip -->
```crystal
# worker.cr
require "./src/jobs"

JoobQ.forge
```

```bash
crystal run src/server.cr   # the web process
crystal run worker.cr       # the worker process
```

In a generated project `azu jobs:worker` replaces the second command.
{% endstep %}
{% endstepper %}
