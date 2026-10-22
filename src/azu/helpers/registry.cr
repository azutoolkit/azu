require "crinja"

module Azu
  module Helpers
    # Thread-safe registry for template helpers.
    #
    # The Registry stores all registered filters, functions, globals, and tests,
    # then applies them to the Crinja environment when templates are rendered.
    #
    # ## Thread Safety
    #
    # All operations are protected by a mutex to ensure thread-safe registration
    # from multiple fibers during application startup.
    #
    # ## Usage
    #
    # Helpers are typically registered via the DSL macros in `Azu::Helpers`,
    # but can also be registered directly:
    #
    # ```
    # filter = Crinja.filter(:my_filter) { target.to_s.upcase }
    # Azu::Helpers::Registry.register_filter(:my_filter, filter)
    # ```
    class Registry
      @@filters = {} of Symbol => Crinja::Callable
      @@functions = {} of Symbol => Crinja::Callable
      @@tests = {} of Symbol => Crinja::Callable
      @@globals = {} of Symbol => Crinja::Value
      @@revision = 0_u64
      @@mutex = Mutex.new

      # Changes whenever a helper is registered or the registry is reset, so a holder of an
      # environment can tell whether it needs `apply_to` again.
      def self.revision : UInt64
        @@mutex.synchronize { @@revision }
      end

      # Register a filter by name.
      #
      # ```
      # filter = Crinja.filter(:upcase) { target.to_s.upcase }
      # Registry.register_filter(:upcase, filter)
      # ```
      def self.register_filter(name : Symbol, filter : Crinja::Callable) : Nil
        @@mutex.synchronize do
          @@filters[name] = filter
          @@revision += 1
        end
      end

      # Register a function by name.
      #
      # ```
      # func = Crinja.function(:now) { Time.utc.to_s }
      # Registry.register_function(:now, func)
      # ```
      def self.register_function(name : Symbol, function : Crinja::Callable) : Nil
        @@mutex.synchronize do
          @@functions[name] = function
          @@revision += 1
        end
      end

      # Register a test by name.
      #
      # ```
      # test = Crinja.test(:blank) { target.to_s.blank? }
      # Registry.register_test(:blank, test)
      # ```
      def self.register_test(name : Symbol, test : Crinja::Callable) : Nil
        @@mutex.synchronize do
          @@tests[name] = test
          @@revision += 1
        end
      end

      # Register a global variable.
      #
      # ```
      # Registry.register_global(:app_name, "My App")
      # ```
      def self.register_global(name : Symbol, value) : Nil
        @@mutex.synchronize do
          @@globals[name] = Crinja::Value.new(value)
          @@revision += 1
        end
      end

      # Apply all registered helpers to a Crinja environment.
      #
      # Applying is idempotent: the same registry always yields the same environment, so a
      # repeated call is safe. Skip it while `revision` is unchanged.
      #
      # ```
      # crinja = Crinja.new
      # Registry.apply_to(crinja)
      # ```
      def self.apply_to(crinja : Crinja) : Nil
        @@mutex.synchronize do
          # Apply filters
          @@filters.each do |name, filter|
            crinja.filters[name] = filter
          end

          # Apply functions
          @@functions.each do |name, function|
            crinja.functions[name] = function
          end

          # Apply tests
          @@tests.each do |name, test|
            crinja.tests[name] = test
          end

          # Apply globals
          @@globals.each do |name, value|
            crinja.context[name.to_s] = value
          end
        end
      end

      # Get all registered filters.
      def self.filters : Hash(Symbol, Crinja::Callable)
        @@mutex.synchronize do
          @@filters.dup
        end
      end

      # Get all registered functions.
      def self.functions : Hash(Symbol, Crinja::Callable)
        @@mutex.synchronize do
          @@functions.dup
        end
      end

      # Get all registered tests.
      def self.tests : Hash(Symbol, Crinja::Callable)
        @@mutex.synchronize do
          @@tests.dup
        end
      end

      # Get all registered globals.
      def self.globals : Hash(Symbol, Crinja::Value)
        @@mutex.synchronize do
          @@globals.dup
        end
      end

      # Reset all registered helpers.
      #
      # Useful for testing to ensure a clean slate.
      #
      # ```
      # Registry.reset!
      # ```
      def self.reset! : Nil
        @@mutex.synchronize do
          @@filters.clear
          @@functions.clear
          @@tests.clear
          @@globals.clear
          @@revision += 1
        end
      end

      # Get count of registered filters.
      def self.filter_count : Int32
        @@mutex.synchronize do
          @@filters.size
        end
      end

      # Get count of registered functions.
      def self.function_count : Int32
        @@mutex.synchronize do
          @@functions.size
        end
      end

      # Get count of registered tests.
      def self.test_count : Int32
        @@mutex.synchronize do
          @@tests.size
        end
      end

      # Get count of registered globals.
      def self.global_count : Int32
        @@mutex.synchronize do
          @@globals.size
        end
      end

      # Check if a filter is registered.
      def self.has_filter?(name : Symbol) : Bool
        @@mutex.synchronize do
          @@filters.has_key?(name)
        end
      end

      # Check if a function is registered.
      def self.has_function?(name : Symbol) : Bool
        @@mutex.synchronize do
          @@functions.has_key?(name)
        end
      end

      # Check if a test is registered.
      def self.has_test?(name : Symbol) : Bool
        @@mutex.synchronize do
          @@tests.has_key?(name)
        end
      end

      # Check if a global is registered.
      def self.has_global?(name : Symbol) : Bool
        @@mutex.synchronize do
          @@globals.has_key?(name)
        end
      end
    end
  end
end
