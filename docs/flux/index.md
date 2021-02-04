# flux

[![Codacy Badge](https://api.codacy.com/project/badge/Grade/ad96c04bc4c644a8b2fbba4a860e5269)](https://app.codacy.com/manual/eliasjpr/flux?utm_source=github.com&utm_medium=referral&utm_content=eliasjpr/flux&utm_campaign=Badge_Grade_Settings)

Flux makes it easy to Test web applications by simulating a Real User would interact with your web based app.

This project uses **Marionette**

Marionette is an automation driver for Mozilla’s Gecko engine. It can remotely control either the UI or the internal JavaScript of a Gecko platform, such as Firefox. It can control both the chrome (i.e. menus and functions) or the content (the webpage loaded inside the browsing context), giving a high level of control and ability to replicate user actions. In addition to performing actions on the browser, Marionette can also read the properties and attributes of the DOM.

If this sounds similar to Selenium/WebDriver then you’re correct! Marionette shares much of the same ethos and API as Selenium/WebDriver, with additional commands to interact with Gecko’s chrome interface. Its goal is to replicate what Selenium does for web content: to enable the tester to have the ability to send commands to remotely control a user agent.

Read more about Marionetter <https://firefox-source-docs.mozilla.org/testing/marionette/Intro.html>

## How does it work

Marionette consists of two parts: a server which takes requests and executes them in Gecko, and a client. The client sends commands to the server and the server executes the command inside the browser.

## When would I use it

If you want to perform UI tests with browser chrome or content, Marionette is the tool you’re looking for! You can use it to control either web content, or Firefox itself.

## Installation

1.  Add the dependency to your `shard.yml`:

    ```yaml
    dependencies:
      flux:
        github: azutoolkit/flux
    ```

2.  Run `shards install`

## Usage

```crystal
require "flux"
```

```crystal
require "./spec_helper"

class UserFlux < Flux
  def signup
    step do
      visit "http://localhost:4000/register"
      fill "first_name", "John"
      fill "last_name", "Doe"
      fill "email", "john.doe@example.com"
      fill "password", "example"
      fill "password_confirm", "example"
      checkbox id: "terms-checkbox", checked: true
      submit "submit"
    end
  end
end

describe "User Signup" do
  user = UserFlux.new

  it "User visits site" do
    user.signup

    # ...add assertions...
  end
end
```

Run your tests

```crystal
❯ crystal spec
[DEBUG  ] - Using firefox executable at /usr/bin/firefox
[DEBUG  ] - Launching browser
[DEBUG  ] - Initialized a new browser instance
[DEBUG  ] - Creating new session with capabilities: {acceptInsecureCerts: false, timeouts: {implicit: 30000, pageLoad: 30000, script: 30000}}
*** You are running in headless mode.
[DEBUG  ] - Navigating to http://localhost:4000/register
[DEBUG  ] - Executing script
[DEBUG  ] - Quitting browser
[DEBUG  ] - Setting browser context to Chrome
[DEBUG  ] - Executing script
[DEBUG  ] - Setting browser context to Content
.

Finished in 1.36 seconds
1 examples, 0 failures, 0 errors, 0 pending
```

## Development

Help with:

-   Add configurator to customize the driver
-   Define more usable and meaningful helper methods for testing
-   Your ideas welcome, feel free to open an issue or PR

## Contributing

    1. Fork it (<https://github.com/azutoolkit/flux/fork>)
    2. Create your feature branch (`git checkout -b my-new-feature`)
    3. Commit your changes (`git commit -am 'Add some feature'`)
    4. Push to the branch (`git push origin my-new-feature`)
    5. Create a new Pull Request

## Contributors

-   [Elias J. Perez](https://github.com/eliasjpr) - creator and maintainer
