module Azu
  # Base class for database models.
  #
  # ```
  # class User < Azu::Model
  #   table :users
  #
  #   column id : Int64, primary_key: true
  #   column email : String, validate: :email, unique: true
  #   column name : String
  #   column role : String = "member"
  #   timestamps
  #
  #   has_many posts : Post
  #   has_one profile : Profile
  #   validates :name, presence: true, length: 2..80
  #   scope :recent, -> { order(created_at: :desc) }
  # end
  # ```
  #
  # No schema constant or connection code is needed: `Azu::Database` connects
  # lazily and learns the columns from the `column` declarations. Tables
  # themselves are created by migrations.
  #
  # Declare `table` and the `primary_key` column first; associations and
  # validations come after. Association targets must be written as full
  # constant paths (`Blog::Post`) because CQL resolves them at compile time.
  abstract class Model
    # Raised by `has_many ..., dependent: :restrict_with_error` when children exist.
    class DependentRecordsExist < Azu::Database::Error
    end

    macro inherited
      macro finished
        __azu_model_finish
      end
    end

    # Binds the model to a table.
    macro table(name)
      AZU_TABLE = {{name}}
    end

    # Declares a column. `primary_key: true` selects the key type and includes CQL's model.
    #
    # Options: `primary_key`, `unique`, `index`, `validate` (`:email`, `:url`, `:uuid`).
    # A default is the right-hand side (`column role : String = "member"`); nilable
    # types (`String?`) are nullable columns.
    macro column(decl, **opts)
      {% raise "column expects `column name : Type`" unless decl.is_a?(TypeDeclaration) %}
      {% name = decl.var %}
      {% type = decl.type %}
      {% value = decl.value %}
      {% table = @type.constant("AZU_TABLE") %}
      {% raise "declare `table :name` before `column #{name}` in #{@type}" unless table %}
      {% nilable = type.is_a?(Union) && type.types.any? { |t| t.stringify == "Nil" || t.stringify == "::Nil" } %}
      {% base = nilable ? type.types.reject { |t| t.stringify == "Nil" || t.stringify == "::Nil" }.first : type %}

      {% if opts[:primary_key] %}
        include ::CQL::ActiveRecord::Model({{base}})
        AZU_PK = {{name.stringify}}
        ::Azu::Database::Registry.add({{table}}, ->(t : ::CQL::Table) { t.primary(:{{name.id}}, {{base}}); nil })
      {% else %}
        AZU_COL_{{name.id.upcase}} = {{name.stringify}}
        property {{name.id}} : {{type}} = {% if value %}{{value}}{% else %}__azu_default({{type}}, {{nilable}}){% end %}
        ::Azu::Database::Registry.add({{table}}, ->(t : ::CQL::Table) {
          t.column(:{{name.id}}, {{base}}, null: {{nilable}}, default: {% if value %}{{value}}.as(DB::Any){% else %}nil{% end %}, unique: {{opts[:unique] ? true : false}}, index: {{opts[:index] ? true : false}})
          nil
        })
        {% if opts[:validate] %}
          __azu_format_validator(:{{name.id}}, {{opts[:validate]}})
        {% end %}
        {% if opts[:unique] %}
          __azu_uniqueness_validator(:{{name.id}}, nil)
        {% end %}
      {% end %}
    end

    # `created_at` / `updated_at`, maintained automatically on save.
    macro timestamps
      {% table = @type.constant("AZU_TABLE") %}
      {% raise "declare `table :name` before `timestamps` in #{@type}" unless table %}
      property created_at : Time? = nil
      property updated_at : Time? = nil
      ::Azu::Database::Registry.add({{table}}, ->(t : ::CQL::Table) { t.timestamps; nil })
    end

    # Soft deletes through a nullable `deleted_at` column (`delete!` marks, `force_delete!` removes).
    macro soft_delete
      {% table = @type.constant("AZU_TABLE") %}
      {% raise "declare `table :name` before `soft_delete` in #{@type}" unless table %}
      include ::CQL::ActiveRecord::SoftDeletable
      ::Azu::Database::Registry.add({{table}}, ->(t : ::CQL::Table) { t.timestamp(:deleted_at, null: true); nil })
    end

    # Validations: `validates :email, presence: true, format: :email, uniqueness: true, length: 3..120`.
    #
    # * `format:` takes `:email`, `:url`, `:uuid` or a Regex.
    # * `uniqueness: true` checks the table (self excluded); `uniqueness: {message: "..."}` sets the text.
    #   Back it with a unique index: the check is advisory under concurrency.
    # * `length:` is a Range; `message:` customises the native rules.
    # * Everything else (`presence`, `required`, `gt`, `lt`, `in`, `confirmation`, `accept`, `on`, ...)
    #   passes straight through to CQL's `validate`.
    #
    # CQL keeps one rule set per attribute, so use a single `validates` per field
    # (symbol formats and uniqueness are separate validators and always compose).
    macro validates(field, **opts)
      {% native = [] of Nil %}
      {% for key, value in opts %}
        {% if key == :uniqueness %}
          __azu_uniqueness_validator({{field}}, {{value}})
        {% elsif key == :format && value.is_a?(SymbolLiteral) %}
          __azu_format_validator({{field}}, {{value}})
        {% else %}
          {% native << key %}
        {% end %}
      {% end %}
      {% if native.size > 0 %}
        validate {{field}}{% for key, value in opts %}{% if native.includes?(key) %}, {% if key == :format %}match: {{value}}{% elsif key == :length %}size: {{value}}{% else %}{{key.id}}: {{value}}{% end %}{% end %}{% end %}
      {% end %}
    end

    macro __azu_format_validator(field, kind)
      {% pattern = kind == :email ? "::Azu::Model::EMAIL_FORMAT" : (kind == :url ? "::Azu::Model::URL_FORMAT" : (kind == :uuid ? "::Azu::Model::UUID_FORMAT" : nil)) %}
      {% raise "unknown format #{kind}; use :email, :url, :uuid or a Regex" unless pattern %}
      class AzuFormat{{field.id.camelcase}}{{kind.id.camelcase}} < ::CQL::ActiveRecord::Validations::CustomValidator
        def initialize(@record : {{@type}})
        end

        def valid? : Array(::CQL::ActiveRecord::Validations::Error)
          value = @record.{{field.id}}
          errors = [] of ::CQL::ActiveRecord::Validations::Error
          return errors if value.nil? || value.to_s.empty?
          unless {{pattern.id}}.matches?(value.to_s)
            errors << ::CQL::ActiveRecord::Validations::Error.new({{field}}, "{{field.id}} must be a valid {{kind.id}}")
          end
          errors
        end
      end
      use AzuFormat{{field.id.camelcase}}{{kind.id.camelcase}}
    end

    macro __azu_uniqueness_validator(field, options)
      class AzuUniqueness{{field.id.camelcase}} < ::CQL::ActiveRecord::Validations::CustomValidator
        def initialize(@record : {{@type}})
        end

        def valid? : Array(::CQL::ActiveRecord::Validations::Error)
          value = @record.{{field.id}}
          errors = [] of ::CQL::ActiveRecord::Validations::Error
          return errors if value.nil?
          taken = {{@type}}.where({{field.id}}: value).all.any? { |other| other.id != @record.id }
          if taken
            errors << ::CQL::ActiveRecord::Validations::Error.new({{field}}, {% if options.is_a?(NamedTupleLiteral) && options[:message] %}{{options[:message]}}{% else %}"{{field.id}} has already been taken"{% end %})
          end
          errors
        end
      end
      use AzuUniqueness{{field.id.camelcase}}
    end

    # `has_many posts : Post, dependent: :destroy`
    #
    # `dependent:` acts when the parent is deleted (CQL records the option but never applies it):
    # `:destroy` deletes each child through its own `delete!`, `:delete_all` removes them in one
    # statement, `:restrict_with_error` raises `Azu::Model::DependentRecordsExist` while children exist.
    macro has_many(decl, **opts)
      {% fk = opts[:foreign_key] || "#{@type.name.split("::").last.underscore.id}_id".id.symbolize %}
      {% dependent = opts[:dependent] %}
      has_many :{{decl.var.id}}, {{decl.type}}, foreign_key: {{fk}}{% for key, value in opts %}{% if key != :foreign_key %}, {{key.id}}: {{value}}{% end %}{% end %}

      def {{decl.var.id}}
        _azu_lazy_association(:{{decl.var.id}}) unless @{{decl.var.id}}.try(&.loaded?)
        previous_def
      end

      {% if dependent == :destroy || dependent == :delete_all || dependent == :restrict_with_error %}
        def __azu_dependent_{{decl.var.id}} : Nil
          parent_id = id
          return if parent_id.nil?
          {% if dependent == :destroy %}
            {{decl.type}}.where({ {{fk}} => parent_id }).all.each(&.delete!)
          {% elsif dependent == :delete_all %}
            {{decl.type}}.delete_by!({{fk.id}}: parent_id)
          {% else %}
            if {{decl.type}}.where({ {{fk}} => parent_id }).count > 0
              raise ::Azu::Model::DependentRecordsExist.new("cannot delete {{@type.name.split("::").last.id}} #{parent_id}: it still has {{decl.var.id}}")
            end
          {% end %}
        end

        def delete!
          __azu_dependent_{{decl.var.id}}
          previous_def
        end
      {% end %}
    end

    # `has_one profile : Profile`. Works with `preload(:profile)` (CQL itself only preloads has_many).
    macro has_one(decl, **opts)
      {% name = decl.var.id %}
      {% klass = decl.type %}
      {% fk = opts[:foreign_key] || "#{@type.name.split("::").last.underscore.id}_id".id.symbolize %}
      has_one :{{name}}, {{klass}}, foreign_key: {{fk.id}}{% for key, value in opts %}{% if key != :foreign_key %}, {{key.id}}: {{value}}{% end %}{% end %}

      def _set_preloaded_{{name}}(record : {{klass}}?) : Nil
        @_cached_{{name}} = record
        @_{{name}}_loaded = true
      end

      def {{name}}
        _azu_lazy_association(:{{name}}) unless @_{{name}}_loaded
        previous_def
      end

      def self._preload_{{name}}(records : Array(self), parent_ids : Array) : Nil
        return if records.empty? || parent_ids.empty?
        related = {{klass}}.where({ {{fk}} => parent_ids }).all
        by_parent = {} of typeof(related.first.{{fk.id}}.not_nil!) => {{klass}}
        related.each do |record|
          key = record.{{fk.id}}
          by_parent[key] = record if key
        end
        records.each do |record|
          id = record.id
          record._set_preloaded_{{name}}(id ? by_parent[id]? : nil)
        end
      end
    end

    # `belongs_to user : User` (foreign key defaults to `user_id`; declare that column first).
    # Works with `preload(:user)` (CQL itself only preloads has_many).
    macro belongs_to(decl, **opts)
      {% name = decl.var.id %}
      {% klass = decl.type %}
      {% fk = opts[:foreign_key] || "#{decl.var.id}_id".id.symbolize %}
      belongs_to :{{name}}, {{klass}}, {{fk}}{% for key, value in opts %}{% if key != :foreign_key %}, {{key.id}}: {{value}}{% end %}{% end %}

      def _set_preloaded_{{name}}(record : {{klass}}?) : Nil
        @_cached_{{name}} = record
        @_{{name}}_loaded = true
      end

      def {{name}}
        _azu_lazy_association(:{{name}}) unless @_{{name}}_loaded
        previous_def
      end

      def self._preload_{{name}}(records : Array(self), parent_ids : Array) : Nil
        keys = records.compact_map(&.{{fk.id}}).uniq!
        return if keys.empty?
        by_id = {} of typeof(keys.first) => {{klass}}
        {{klass}}.where({:id => keys}).all.each do |record|
          id = record.id
          by_id[id] = record if id
        end
        records.each do |record|
          key = record.{{fk.id}}
          record._set_preloaded_{{name}}(key ? by_id[key]? : nil)
        end
      end
    end

    # `many_to_many tags : Tag, through: Tagging` (join model with `note_id` / `tag_id` columns).
    #
    # Override the join columns with `foreign_key:` (this model's key in the join table) and
    # `association_foreign_key:` (the target's). The reader returns a small collection:
    # enumerable, `<<` (idempotent), `delete(record)` and `clear` change the join rows only.
    # (CQL's own `many_to_many` derives table names from class names and cannot be used with
    # namespaced models.)
    macro many_to_many(decl, through, **opts)
      {% name = decl.var.id %}
      {% klass = decl.type %}
      {% owner = @type %}
      {% fk = opts[:foreign_key] || "#{@type.name.split("::").last.underscore.id}_id".id.symbolize %}
      {% afk = opts[:association_foreign_key] || "#{klass.stringify.split("::").last.underscore.id}_id".id.symbolize %}

      class AzuMany{{name.camelcase}}
        include Enumerable({{klass}})

        def initialize(@owner : {{owner}})
        end

        def each(& : {{klass}} ->) : Nil
          to_a.each { |record| yield record }
        end

        def to_a : Array({{klass}})
          owner_id = @owner.id
          return [] of {{klass}} if owner_id.nil?
          ids = {{through}}.where({ {{fk}} => owner_id }).all.compact_map(&.{{afk.id}})
          return [] of {{klass}} if ids.empty?
          {{klass}}.where({:id => ids}).all
        end

        def <<(record : {{klass}}) : self
          owner_id, target_id = ids_for(record)
          unless {{through}}.where({ {{fk}} => owner_id, {{afk}} => target_id }).count > 0
            {{through}}.create!({{fk.id}}: owner_id, {{afk.id}}: target_id)
          end
          self
        end

        def delete(record : {{klass}}) : Nil
          owner_id, target_id = ids_for(record)
          {{through}}.delete_by!({{fk.id}}: owner_id, {{afk.id}}: target_id)
        end

        def clear : Nil
          owner_id = @owner.id
          {{through}}.delete_by!({{fk.id}}: owner_id) if owner_id
        end

        private def ids_for(record : {{klass}})
          owner_id = @owner.id || raise ::Azu::Database::Error.new("save the {{owner.name.split("::").last.id}} before changing its {{name}}")
          target_id = record.id || raise ::Azu::Database::Error.new("save the {{klass.stringify.split("::").last.id}} before adding it to {{name}}")
          {owner_id, target_id}
        end
      end

      def {{name}} : AzuMany{{name.camelcase}}
        AzuMany{{name.camelcase}}.new(self)
      end
    end

    # Default for a column declared without one so `Model.new` always works.
    macro __azu_default(type, nilable)
      {% if nilable %}
        nil
      {% else %}
        {% name = type.stringify %}
        {% if name == "String" %}""
        {% elsif name == "Int32" %}0
        {% elsif name == "Int64" %}0_i64
        {% elsif name == "Float64" %}0.0
        {% elsif name == "Bool" %}false
        {% elsif name == "Time" %}Time.unix(0)
        {% elsif name == "UUID" %}UUID.empty
        {% elsif name == "JSON::Any" %}JSON::Any.new(nil)
        {% elsif name.starts_with?("Array(") %}{{type}}.new
        {% else %}{% raise "give column of type #{name} a default value or make it nilable" %}
        {% end %}
      {% end %}
    end

    macro __azu_model_finish
      {% table = @type.constant("AZU_TABLE") %}
      {% if table %}
        def self.table : Symbol
          {{table}}
        end

        def self.schema : ::CQL::Schema
          ::Azu::Database.schema
        end

        {% unless @type.methods.any? { |m| m.name == "initialize" && m.args.empty? } %}
          # DB::Serializable only defines `initialize(rs)`, so `new` needs an explicit no-arg form.
          def initialize
          end
        {% end %}

        # `User.paginate(page: 2, per_page: 20)` -> `Azu::Page(User)` (chainable after scopes too).
        def self.paginate(page : Int32 = 1, per_page : Int32 = 20) : ::Azu::Page({{@type}})
          query.paginate(page, per_page)
        end

        def self.order_by(**fields)
          query.order_by(**fields)
        end

        def self.build(**fields)
          instance = new
          instance.attributes(**fields)
          instance
        end

        # Validates, runs callbacks and inserts. Raises on invalid data.
        def self.create!(**fields)
          instance = build(**fields)
          instance.save!
          instance
        end

        # Same as `create!` inside an existing transaction.
        def self.create!(tx : ::DB::Transaction, **fields) : {{@type}}
          created = nil
          transaction(tx) { |_| created = create!(**fields) }
          created.not_nil!
        end

        # CQL collects column values as `DB::Any`, which has no JSON; `JSON::Any` columns (json,
        # jsonb) are written as JSON text, which PostgreSQL casts on insert and update.
        def attributes
          hash = Hash(Symbol, DB::Any).new
          {% verbatim do %}
            {% for ivar in @type.instance_vars %}
              {% field = ivar.annotation(DB::Field) %}
              {% unless field && field.named_args[:ignore] %}
                {% key = field && field.named_args[:key] ? field.named_args[:key].id : ivar.id %}
                {% type = ivar.type.stringify %}
                {% if type.includes?("JSON::Any") %}
                  _value = @{{ivar.id}}
                  hash[:{{key}}] = _value.nil? ? nil : _value.to_json
                {% elsif type.includes?("UUID") %}
                  _value = @{{ivar.id}}
                  hash[:{{key}}] = _value.nil? ? nil : _value.to_s
                {% else %}
                  hash[:{{key}}] = @{{ivar.id}}
                {% end %}
              {% end %}
            {% end %}
          {% end %}
          hash
        end
      {% end %}
    end
  end
end
