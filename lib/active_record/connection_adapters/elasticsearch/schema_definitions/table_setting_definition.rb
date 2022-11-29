# frozen_string_literal: true

require 'active_record/connection_adapters/elasticsearch/schema_definitions/attribute_methods'
require 'active_model/validations'

module ActiveRecord
  module ConnectionAdapters
    module Elasticsearch
      class TableSettingDefinition
        include AttributeMethods
        include ActiveModel::Validations

        # exclude settings, that are provided through the API but are not part of the index-settings
        IGNORE_NAMES = ['provided_name', 'creation_date', 'uuid', 'version'].freeze

        # available setting names
        # - see @ https://www.elastic.co/guide/en/elasticsearch/reference/current/index-modules.html#index-modules-settings
        STATIC_NAMES = ['number_of_shards', 'number_of_routing_shards', 'codec', 'routing_partition_size',
                        'soft_deletes.enabled', 'soft_deletes.retention_lease.period',
                        'load_fixed_bitset_filters_eagerly', 'shard.check_on_startup',

                        # modules
                        'analysis', 'routing', 'unassigned', 'merge', 'similarity', 'search', 'store', 'translog',
                        'indexing_pressure'].freeze

        DYNAMIC_NAMES = ['number_of_replicas', 'auto_expand_replicas', "search.idle.after", 'refresh_interval',
                         'max_result_window', 'max_inner_result_window', 'max_rescore_window',
                         'max_docvalue_fields_search', 'max_script_fields', 'max_ngram_diff', 'max_shingle_diff',
                         'max_refresh_listeners', 'analyze.max_token_count', 'highlight.max_analyzed_offset',
                         'max_terms_count', 'max_regex_length', 'query.default_field', 'routing.allocation.enable',
                         'routing.rebalance.enable', 'gc_deletes', 'default_pipeline', 'final_pipeline', 'hidden'].freeze

        VALID_NAMES = (STATIC_NAMES + DYNAMIC_NAMES).freeze

        # attributes
        attr_accessor :name
        attr_accessor :value

        # validations
        validates_presence_of :name
        validate :_validate_flat_names
        validate :_validate_static_name

        def self.match_ignore_names?(name)
          IGNORE_NAMES.any? { |invalid| name.match?(invalid) }
        end

        def self.match_valid_names?(name)
          VALID_NAMES.any? { |invalid| name.match?(invalid) }
        end

        def self.match_dynamic_names?(name)
          DYNAMIC_NAMES.any? { |invalid| name.match?(invalid) }
        end

        def self.match_static_names?(name)
          STATIC_NAMES.any? { |invalid| name.match?(invalid) }
        end

        def initialize(name, value)
          @name  = name.to_s
          @value = value
        end

        def static?
          !dynamic?
        end

        def dynamic?
          @dynamic = flat_names.all? { |flat_name| self.class.match_dynamic_names?(flat_name) } if @dynamic.nil?
          @dynamic
        end

        # returns a array of flat names
        def flat_names
          @flat_names ||= _generate_flat_names.uniq
        end

        private

        def _validate_flat_names
          invalid_name = flat_names.detect { |flat_name| !self.class.match_valid_names?(flat_name) }

          invalid!("invalid name", :name) if invalid_name.present?
        end

        def _validate_static_name
          return true if dynamic?
          return true if ['missing', 'close'].include?(_table_status)

          invalid!("is static for an open index", :name)
        end

        def _generate_flat_names(parent = name, current = value)
          ret = []
          if current.is_a?(Hash)
            current.each do |k, v|
              ret += _generate_flat_names("#{parent}.#{k}", v)
            end
          else
            ret << parent.to_s
          end

          ret
        end

        def _table_status
          return 'missing' unless state?
          state[:status]
        end
      end
    end
  end
end
