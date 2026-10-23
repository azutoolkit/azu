module Azu
  module CQL
    # Contract <-> model mapping, resolved entirely at compile time.
    #
    # `construct` builds a `target` from a `source` by matching names: each argument of the target's
    # constructor is read from the source's reader of the same name, then the remaining source fields that
    # the target has a setter for are assigned (`id`, `created_at` and `updated_at` only when named in `only`).
    # Source fields the target does not know are ignored. A constructor argument without a default that the
    # source cannot provide, and a field whose type cannot be converted without loss, are compile errors.
    #
    # Conversions: identical or narrower types, `T` to `T?`, `Int32` to `Int64`, `Float32` to `Float64`,
    # and `Time` or `UUID` to `String` (RFC 3339 and canonical form), each applied through `try` when the
    # source is nilable.
    #
    # Options (all by name, as symbols): `only` / `except` filter source fields; `rename` maps a target
    # attribute to the source field it reads (`rename: {name: :full_name}`).
    # (A module so the macro is called without a receiver: the model's path then resolves where it is used.)
    module Construct
      macro construct(source, from, target, only = nil, except = nil, rename = nil, setters = true)
      {%
        from = from.resolve
        target = target.resolve
        only_names = only ? only.map(&.id.stringify) : nil
        except_names = except ? except.map(&.id.stringify) : [] of String
        renames = {} of String => String
        (rename || {} of String => String).each { |attribute, field| renames[attribute.id.stringify] = field.id.stringify }
        ivars = {} of String => TypeNode
        from.instance_vars.each { |ivar| ivars[ivar.name.stringify] = ivar.type }
        target_ivars = {} of String => TypeNode
        target.instance_vars.each { |ivar| target_ivars[ivar.name.stringify] = ivar.type }
        allowed = {} of String => Bool
        from.methods.each { |method| allowed[method.name.stringify] = true if method.args.empty? }
        ivars.keys.each { |name| allowed[name] = true if from.has_method?(name) }
        usable = [] of String
        allowed.keys.each do |name|
          usable << name if (only_names.nil? || only_names.includes?(name)) && !except_names.includes?(name)
        end

        # never copied into a record by name, unless `only:` lists the field: the database or the framework sets them
        server_set = setters ? ["id", "created_at", "updated_at"] : [] of String
        best = nil
        best_missing = nil
        target.methods.each do |ctor|
          if ctor.name == "initialize" && !ctor.splat_index && !ctor.double_splat
            missing = [] of String
            ctor.args.each do |arg|
              field = renames[arg.name.stringify] || arg.name.stringify
              copied = usable.includes?(field) && (!server_set.includes?(arg.name.stringify) || (only_names && only_names.includes?(field)))
              missing << "#{arg.name} (read from `#{field.id}`)" if !copied && arg.default_value.class_name == "Nop"
            end
            if missing.empty?
              best = ctor if best.nil? || ctor.args.size > best.args.size
            elsif best_missing.nil? || missing.size < best_missing.size
              best_missing = missing
            end
          end
        end
      %}
      {% if best.nil? %}
        {% raise "Azu::CQL: cannot build #{target} from #{from}: #{target}.new needs " + (best_missing ? best_missing.join(", ") : "an initialize it can call") + ", which #{from} does not provide (is it excluded by only:/except:?). Add the field to #{from}, give the constructor argument a default, or map it with rename: {attribute: :field}." %}
      {% end %}
      {%
        # {attribute, field, constructor argument?} for everything that is copied
        pairs = [] of ArrayLiteral
        used = [] of String
        best.args.each do |arg|
          attribute = arg.name.stringify
          field = renames[attribute] || attribute
          if usable.includes?(field) && (!server_set.includes?(attribute) || (only_names && only_names.includes?(field)))
            used << field
            pairs << [attribute, field, true, target_ivars[attribute] || (arg.restriction ? arg.restriction.resolve? : nil)]
          end
        end
        if setters
          ivars.keys.each do |field|
            attribute = renames.keys.find { |key| renames[key] == field } || field
            explicit = only_names && only_names.includes?(field)
            renamed_elsewhere = renames[attribute] && renames[attribute] != field # a field named like a renamed attribute must not overwrite it
            if !used.includes?(field) && usable.includes?(field) && !renamed_elsewhere && (explicit || !server_set.includes?(attribute)) && target.has_method?(attribute + "=")
              pairs << [attribute, field, false, target_ivars[attribute]]
            end
          end
        end

        exprs = [] of String
        pairs.each do |pair|
          attribute = pair[0]
          field = pair[1]
          from_type = ivars[field]
          to_type = pair[3]
          expr = "__azu_source." + field
          if from_type && to_type && !(from_type <= to_type)
            from_base = from_type.union? ? from_type.union_types.reject { |type| type.stringify == "Nil" }.first : from_type
            to_base = to_type.union? ? to_type.union_types.reject { |type| type.stringify == "Nil" }.first : to_type
            conversion = nil
            conversion = ".to_rfc3339" if to_base.stringify == "String" && from_base.stringify == "Time"
            conversion = ".to_s" if to_base.stringify == "String" && from_base.stringify == "UUID"
            conversion = ".to_i64" if to_base.stringify == "Int64" && from_base.stringify == "Int32"
            conversion = ".to_f64" if to_base.stringify == "Float64" && from_base.stringify == "Float32"
            conversion = "" if from_base <= to_base
            if conversion.nil?
              raise "Azu::CQL: cannot map #{from}##{field.id} (#{from_type}) to #{target}##{attribute.id} (#{to_type}): the types are not convertible without loss. Make them match" + (pair[2] ? "." : ", or leave the field out with except: [:#{field.id}].")
            elsif from_type.nilable? && !to_type.nilable?
              raise "Azu::CQL: cannot map #{from}##{field.id} (#{from_type}) to #{target}##{attribute.id} (#{to_type}): the source may be nil. Make #{from}##{field.id} non-nilable or #{target}##{attribute.id} nilable" + (pair[2] ? "." : ", or leave the field out with except: [:#{field.id}].")
            elsif conversion != ""
              expr = from_type.nilable? ? expr + ".try(&" + conversion + ")" : expr + conversion
            end
          end
          exprs << expr
        end
      %}
      __azu_source = {{ source }}
      __azu_record = {{ target }}.new(
        {% for pair, index in pairs %}
          {% if pair[2] %}
            {{ pair[0].id }}: {{ exprs[index].id }},
          {% end %}
        {% end %}
      )
      {% for pair, index in pairs %}
        {% unless pair[2] %}
          __azu_record.{{ pair[0].id }} = {{ exprs[index].id }}
        {% end %}
      {% end %}
      __azu_record
    end
    end

    # Maps a request contract onto a model: `request.to_model(User)`. Declare `map_to User, except: [...],
    # rename: {...}` in the request to customize (see `construct`).
    module ModelMapping
      include Construct

      def to_model(model : M.class) : M forall M
        construct(self, {{ @type }}, {{ M }})
      end

      macro map_to(model, only = nil, except = nil, rename = nil)
        def to_model(model : {{ model }}.class) : {{ model }}
          construct(self, {{ @type }}, {{ model }}, {{ only }}, {{ except }}, {{ rename }})
        end
      end
    end

    # `include Azu::CQL::FromRequest` in a model: `User.from_request(request)`.
    module FromRequest
      macro included
        def self.from_request(request)
          request.to_model(self)
        end
      end
    end

    # `include Azu::CQL::FromModel` in a response struct: `UserResponse.from(user)` reads the
    # constructor arguments from the model's readers of the same name (it never assigns setters).
    # `map_from User, except: [...], rename: {...}` customizes (see `construct`).
    module FromModel
      include Construct

      macro included
        def self.from(model : S) : self forall S
          construct(model, \{{ S }}, {{ @type }}, setters: false)
        end
      end

      macro map_from(model, only = nil, except = nil, rename = nil)
        def self.from(model : {{ model }}) : self
          construct(model, {{ model }}, {{ @type }}, {{ only }}, {{ except }}, {{ rename }}, setters: false)
        end
      end
    end
  end
end

module Azu::Request
  include Azu::CQL::ModelMapping
end
