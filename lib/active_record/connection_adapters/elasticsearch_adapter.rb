# frozen_string_literal: true

require 'active_record/connection_adapters'

# new
require 'active_record/connection_adapters/elasticsearch/column'
require 'active_record/connection_adapters/elasticsearch/database_statements'
require 'active_record/connection_adapters/elasticsearch/quoting'
require 'active_record/connection_adapters/elasticsearch/schema_statements'
require 'active_record/connection_adapters/elasticsearch/type'

require 'arel/visitors/elasticsearch'
require 'arel/collectors/elasticsearch_query'

gem 'elasticsearch'
require 'elasticsearch'

module ActiveRecord # :nodoc:
  module ConnectionHandling # :nodoc:
    def elasticsearch_connection(config)
      config          = config.symbolize_keys

      # move 'host' to 'hosts'
      config[:hosts]  = config.delete(:host) if config[:host]

      # enable logging (Rails.logger)
      config[:logger] = logger if config.delete(:log)

      ConnectionAdapters::ElasticsearchAdapter.new(
        ConnectionAdapters::ElasticsearchAdapter.new_client(config),
        logger,
        config
      )
    end
  end

  module ConnectionAdapters # :nodoc:
    class ElasticsearchAdapter < AbstractAdapter
      ADAPTER_NAME = "Elasticsearch"

      # defines the Elasticsearch 'base' structure, which is always included but cannot be resolved through mappings ...
      BASE_STRUCTURE = [
        { 'name' => '_id', 'type' => 'string', 'null' => false, 'primary' => true },
        { 'name' => '_index', 'type' => 'string', 'null' => false, 'virtual' => true },
        { 'name' => '_score', 'type' => 'float', 'null' => false, 'virtual' => true },
        { 'name' => '_type', 'type' => 'string', 'null' => false, 'virtual' => true }
      ].freeze

      include Elasticsearch::Quoting
      include Elasticsearch::SchemaStatements
      include Elasticsearch::DatabaseStatements

      class << self
        def base_structure_keys
          @base_structure_keys ||= BASE_STRUCTURE.map { |struct| struct['name'] }.freeze
        end

        def new_client(config)
          # IMPORTANT: remove +adapter+ from config - otherwise we mess up with Faraday::AdapterRegistry
          client = ::Elasticsearch::Client.new(config.except(:adapter))
          client.ping
          client
        rescue ::Elastic::Transport::Transport::ServerError => error
          raise ::ActiveRecord::ConnectionNotEstablished, error.message
        end

        private

        def initialize_type_map(m)
          m.register_type 'binary', Type::Binary.new
          m.register_type 'boolean', Type::Boolean.new
          m.register_type 'keyword', Type::String.new

          m.alias_type 'constant_keyword', 'keyword'
          m.alias_type 'wildcard', 'keyword'

          # maybe use integer 8 here ...
          m.register_type 'long', Type::BigInteger.new
          m.register_type 'integer', Type::Integer.new
          m.register_type 'short', Type::Integer.new(limit: 2)
          m.register_type 'byte', Type::Integer.new(limit: 1)
          m.register_type 'double', Type::Float.new(limit: 8)
          m.register_type 'float', Type::Float.new(limit: 4)
          m.register_type 'half_float', Type::Float.new(limit: 2)
          m.register_type 'scaled_float', Type::Float.new(limit: 8, scale: 8)
          m.register_type 'unsigned_long', Type::UnsignedInteger.new

          m.register_type 'date', Type::DateTime.new

          # force a hash
          m.register_type 'object', ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Object.new
          m.alias_type 'flattened', "object"

          # array of objects
          m.register_type 'nested', ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Nested.new

          ip_type = ActiveRecord::ConnectionAdapters::Elasticsearch::Type::FormatString.new(format: /^((25[0-5]|(2[0-4]|1\d|[1-9]|)\d)\.?\b){4}$/)

          m.register_type 'integer_range', ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Range.new(nested_type: Type::Integer.new)
          m.register_type 'float_range', ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Range.new(nested_type: Type::Float.new(limit: 4))
          m.register_type 'long_range', ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Range.new(nested_type: Type::Integer.new(limit: 8))
          m.register_type 'double_range', ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Range.new(nested_type: Type::Float.new(limit: 8))
          m.register_type 'date_range', ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Range.new(nested_type: Type::DateTime.new)
          m.register_type 'ip_range', ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Range.new(nested_type: ip_type)

          m.register_type 'ip', ip_type
          m.register_type 'version', ActiveRecord::ConnectionAdapters::Elasticsearch::Type::FormatString.new(format: /^\d+\.\d+\.\d+[\-\+A-Za-z\.]*$/)
          # m.register_type 'murmur3', Murmur3.new

          m.register_type 'text', Type::Text.new

          # this special Type is required to parse a ES-value into the +nested_type+, array or hash.
          # For arrays & hashes it tries to cast the values with the provided +nested_type+
          # but falls back to provided value if cast fails.
          # This type cannot be accessed through the mapping and is only called @ #lookup_cast_type_from_column
          # @see ActiveRecord::ConnectionAdapters::Elasticsearch::SchemaStatements#lookup_cast_type_from_column
          m.register_type :multicast_value do |_type, nested_type|
            ActiveRecord::ConnectionAdapters::Elasticsearch::Type::MulticastValue.new(nested_type: nested_type)
          end
        end
      end

      # reinitialize the constant with new types
      TYPE_MAP = ActiveRecord::Type::HashLookupTypeMap.new.tap { |m| initialize_type_map(m) }

      def initialize(*args)
        super(*args)

        # prepared statements are not supported by Elasticsearch.
        # documentation for mysql prepares statements @ https://dev.mysql.com/doc/refman/8.0/en/sql-prepared-statements.html
        @prepared_statements = false
      end

      private

      def type_map
        TYPE_MAP
      end

      # catch Elasticsearch Transport-errors to be treated as +StatementInvalid+ (the original message is still readable ...)
      def translate_exception(exception, message:, sql:, binds:)
        case exception
        when Elastic::Transport::Transport::ServerError
          ::ActiveRecord::StatementInvalid.new(message, sql: sql, binds: binds)
        else
          # just forward the exception ...
          exception
        end
      end

      # provide a custom log instrumenter for elasticsearch subscribers
      def log(gate, arguments, name, async: false, &block)
        @instrumenter.instrument(
          "query.elasticsearch_record",
          gate:      gate,
          name:      name,
          arguments: gate == 'core.msearch' ? arguments.deep_dup : arguments,
          async:     async) do
          @lock.synchronize(&block)
        rescue => e
          raise translate_exception_class(e, arguments, [])
        end
      end

      # returns a new collector for the Arel visitor.
      # @return [Arel::Collectors::ElasticsearchQuery]
      def collector
        # IMPORTANT: since prepared statements doesn't make sense for elasticsearch,
        # we don't have to check for +prepared_statements+ here.
        # Also, bindings are (currently) not supported.
        # So, we just need a query collector...
        Arel::Collectors::ElasticsearchQuery.new
      end

      # returns a new visitor to compile Arel into Elasticsearch Hashes (in this case we use a query object)
      # @return [Arel::Visitors::Elasticsearch]
      def arel_visitor
        Arel::Visitors::Elasticsearch.new(self)
      end

      # Builds the result object.
      #
      # This is an internal hook to make possible connection adapters to build
      # custom result objects with response-specific data.
      # @return [ElasticsearchRecord::Result]
      def build_result(response, columns: [], column_types: {})
        ElasticsearchRecord::Result.new(response, columns, column_types)
      end

      # register native types
      ActiveRecord::Type.register(:format_string, ActiveRecord::ConnectionAdapters::Elasticsearch::Type::FormatString, adapter: :elasticsearch)
      ActiveRecord::Type.register(:multicast_value, ActiveRecord::ConnectionAdapters::Elasticsearch::Type::MulticastValue, adapter: :elasticsearch)
      ActiveRecord::Type.register(:object, ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Object, adapter: :elasticsearch, override: false)
      ActiveRecord::Type.register(:range, ActiveRecord::ConnectionAdapters::Elasticsearch::Type::Range, adapter: :elasticsearch)
    end
  end
end