module Azu
  # Allows to test which environment Azu is running in.
  #
  # Azu uses `.env` environment files to load configuration for the application
  #
  # Your `.env` file should not be committed to your application's source control,
  # since each developer / server using your application could require a different
  # environment configuration. Furthermore, this would be a security risk in the
  # event an intruder gains access to your source control repository, since any
  # sensitive credentials would get exposed.
  #
  # The current application environment is determined via the CRYSTAL_ENV variable from your .env file.
  enum Environment
    # Build environment ideal for building images and compiling
    Build
    # Development environment normally developer local development computer
    Development
    # Test environment for running unit tests and component integration tests
    Test
    # Integration environment for running integration tests across network
    Integration
    # Acceptance/System test environment to evaluate the system's compliance with the business requirements and assess whether it is acceptable for delivery
    Acceptance
    # For running in a pipeline environment
    Pipeline
    # Staging environment nearly exact replica of a production environment for software testing
    Staging
    # where software and other products are actually put into operation for their intended uses by end users
    Production

    # Checks if the current environment is in any of the environment listed
    def in?(environments : Array(Symbol))
      environments.any? { |name| self == name }
    end

    # Checks if the current environment matches another environment
    def in?(*environments : Environment)
      in?(environments.to_a)
    end
  end
end
