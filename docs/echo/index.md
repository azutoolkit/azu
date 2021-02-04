# ECHO 


#### Pub/Sub Framework

**Echo** is a messaging framework built in Crystal Language, that applies the Pub/Sub pattern with asynchronous messaging service. **Echo** provides instant event notifications for distributed applications, especially those that are decoupled into smaller, independent building blocks.

# Communication Model

*Echo* uses Topic based messaging, where messages are published to named topics invoked as `Stream(M)` type objects. The `Producer(Messate, Stream)` is the one who creates these `Streams`. `Consumer` subscribe to those topics to receive messages from whereever they appear.

## Types of Streams

**Echo** has 3 types of `Stream` built-in these are:

- **Redis Streams** - Uses Redis Stream data type introduced in Redis 5.0 which models a log data structure in a more abstract way. 
- **Websockets Streams** - Uses WebSockets to provide a long-lived connection to deliver messages from producer to consumers 
- **In-Memory Streams** - Uses Crystal Channels to deliver messages from Producer to Consumers internally within an application

## Core concepts

  - **Stream** A named resource to which messages are sent by publishers.
  - **Producer** A named resource representing the stream of events (messages) from a single, specific topic, to be delivered to the subscribing application (consumers).
  - **Consumer** A named resource representing the application/entity subscribed to a stream to receive events.
  - **Message** The combination of data and (optional) attributes that a producer sends to a Stream(Message) and is eventually delivered to consumers.

## Producer Consumer Relationship

A producer application creates and sends events to a stream. Consumer applications create a subscription to a event to receive messages from it. Communication can be one-to-many (fan-out), many-to-one (fan-in), and many-to-many.

![Producer-Consumer relationships](https://raw.githubusercontent.com/azutoolkit/echo/master/Sub.svg "Producer Consumer Relationship")

## Common use cases

  - Balancing workloads in network clusters. For example, a large queue of tasks can be efficiently distributed among multiple workers.
  - Implementing asynchronous workflows. For example, an order processing application can place an order on a stream, from which it can be processed by one or more workers.
  - Distributing event notifications. For example, a service that accepts user signups can send notifications whenever a new user registers, and downstream services can subscribe to receive notifications of the event.
  - Refreshing distributed caches. For example, an application can publish invalidation events to update the IDs of objects that have changed.
  - Logging to multiple systems. For example, an application can write logs to the monitoring system, to a database for later querying, and so on.
  - Data streaming from various processes or devices. For example, a residential sensor can stream data to backend servers hosted in the cloud.
  - Reliability improvement. For example, a single-zone Compute  service can operate in additional zones by subscribing to a common topic, to recover from failures in a zone or region.


## Installation

1. Add the dependency to your `shard.yml`:

   ```yaml
   dependencies:
     echo:
       github: azutoolkit/echo
   ```

2. Run `shards install`

## Example Usage

`Echo::Redis` is replaceable with `Echo::Memory` and `Echo::WebSocket`

```crystal
require "echo"

struct World
  include Echo::Message
  getter name : String = ""

  def initialize(@name)
  end
end

struct Marco
  include Echo::Message
  getter name = "Marco"
end

class WorldProducer
  include Echo::Producer(World, Echo::Redis)
  include Echo::Producer(Marco, Echo::Redis)

  # subscribe and publish methods are now available
end

class WorldConsumer
  include Echo::Consumer(World, Echo::Redis)
  include Echo::Consumer(Marco, Echo::Redis)

  getter count : Int32 = 0

  def on(event : World | Marco)
    @count += 1
    ...do something...
  end
end
```


## Contributing

1. Fork it (<https://github.com/azutoolkit/echo/fork>)
2. Create your feature branch (`git checkout -b my-new-feature`)
3. Commit your changes (`git commit -am 'Add some feature'`)
4. Push to the branch (`git push origin my-new-feature`)
5. Create a new Pull Request

## Contributors

- [Elias J. Perez](https://github.com/eliasjpr) - creator and maintainer
