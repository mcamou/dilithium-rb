module Dilithium
  module Repository
    module Sequel

      module ValueClassBuilders
        def self.extended(base)
          base.instance_eval do
            def create_object(in_h)
              if in_h.nil?
                nil
              else
                BuilderHelpers.resolve_extended_generic_attributes(self, in_h)
                self.new(in_h)
              end
            end
          end
        end
      end

      class ValueRepository
        def fetch_by_id(*args)
          raise ArgumentError, "wrong number of arguments (#{args.length} for #{@type.identifier_names.length})" unless args.length == @type.identifier_names.length

          condition_h = Hash[@type.identifier_names.zip(args)]
          DefaultFinders.fetch_by_id(@type, condition_h)
        end

        def fetch_by_phantomid(phantom_id)
          table = PersistenceService.table_for(@type)
          res_h = DB[table].select(*@type.identifier_names).where(:_phantomid=>phantom_id.to_i).first
          fetch_by_id(res_h.values)
        end

        def fetch_all
          DefaultFinders.fetch_all(@type)
        end

        def key?(*args)
          raise ArgumentError, "wrong number of arguments (#{args.length} for #{@type.identifier_names.length})" unless args.length == @type.identifier_names.length

          condition_h = Hash[@type.identifier_names.zip(args)]
          DefaultFinders.key?(@type, condition_h)
        end

        private

        def initialize(type)
          raise ArgumentError "#{type} is not a descendant of BaseValue" unless type < BaseValue
          @type = type
        end
      end
    end
  end
end