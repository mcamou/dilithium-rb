# -*- encoding : utf-8 -*-

module Dilithium
  module Mapper

    class NullMapper
    end

    class Sequel
      TRANSACTION_DEFAULT_PARAMS = {rollback: :reraise, deferrable: true}

      def self.transaction(params = TRANSACTION_DEFAULT_PARAMS, &block)
        DB.transaction &block
      end

      def self.insert(entity, parent_id = nil)
        Sequel.check_uow_transaction(entity) unless parent_id  # It's the root

        # First insert version when persisting the root; no need to lock the row/table
        if parent_id.nil?
          entity._version.insert!
        end

        # Then insert model
        entity.id = mapper_for(entity.class).insert(entity, parent_id)

        # Then recurse children for inserting them
        entity.each_child do |child|
          insert(child, entity.id)
        end

        # Then recurse multi_ref for inserting the intermediate table
        entity.each_multi_reference(true) do |ref, ref_attr|
          insert_in_intermediate_table(entity, ref, ref_attr)
        end
      end

      def self.delete(entity, already_versioned=false)
        Sequel.check_uow_transaction(entity)

        unless already_versioned
          entity._version.increment!
          already_versioned = true
        end

        mapper_for(entity.class).delete(entity)

        entity.each_child do |child|
          delete(child, already_versioned)
        end
      end

      def self.update(modified_entity, original_entity, already_versioned=false)
        Sequel.check_uow_transaction(modified_entity)

        already_versioned = mapper_for(modified_entity.class).update(modified_entity, original_entity, already_versioned)

        modified_entity.each_child do |child|
          if child.id.nil?
            unless already_versioned
              modified_entity._version.increment!
              already_versioned = true
            end
            insert(child, modified_entity.id)
          else
            update(child, (original_entity.find_child do |c|
              child.class == c.class && child.id == c.id
            end), already_versioned)
          end
        end

        original_entity.each_child do |child|
          if modified_entity.find_child{|c| child.class == c.class && child.id == c.id}.nil?
            unless already_versioned
              modified_entity._version.increment!
              already_versioned = true
            end
            delete(child, already_versioned)
          end
        end

        modified_entity.each_multi_reference do |ref, ref_attr|
          insert_in_intermediate_table(modified_entity, ref, ref_attr, :update)
        end

        original_entity.each_multi_reference do |ref, ref_attr|
          found_ref = modified_entity.find_multi_reference{|r, attr| ref_attr == attr && ref.id == r.id}
          delete_in_intermediate_table(original_entity, ref, ref_attr) if found_ref.nil?
        end
      end

      private

      def self.check_uow_transaction(base_entity)
        #TODO In the case where base_entity is not a root, should we also check that its root HAS a transaction?
        raise RuntimeError, 'Invalid Transaction' if !base_entity.class.has_parent? && base_entity.transactions.empty?
      end

      def self.mapper_for(entity_class)
        case PersistenceService.mapper_for(entity_class)
          when :leaf
            LeafTableInheritance
          when :class
            ClassTableInheritance
        end
      end

      def self.condition_for(domain_object)
        domain_object.class.identifiers.each_with_object(Hash.new) do | id_desc, h |
          id = id_desc[:identifier]
          h[id] = domain_object.instance_variable_get(:"@#{id}".to_sym)
        end
      end

      def self.verify_identifiers_unchanged(modified_domain_object, modified_data, original_data)
        modified_domain_object.class.identifiers.each do |id_desc|
          id = id_desc[:identifier]
          raise Dilithium::PersistenceExceptions::IllegalUpdateError, "Illegal update, identifiers don't match" unless original_data[id] == modified_data[id]
        end
      end

      private

      def self.insert_in_intermediate_table(dependee, dependent, ref_attr, from=:insert)
        column_dependee, column_dependent, intermediate_table_name = intermediate_table_descriptor(dependee, dependent, ref_attr)

        data = { column_dependee => dependee.id,
                 column_dependent => dependent.id }

        # TODO refactor so that this op below is not always performed (only in :update)
        if Sequel::DB[intermediate_table_name].
          where(column_dependent => dependent.id).
          where(column_dependee => dependee.id).all.empty?

          Sequel.transaction(:rollback=>:nop) do
            Sequel::DB[intermediate_table_name].insert(data)
          end
        end
      end

      private_class_method(:insert_in_intermediate_table)

      def self.delete_in_intermediate_table(dependee, dependent, ref_attr)
        column_dependee, column_dependent, intermediate_table_name = intermediate_table_descriptor(dependee, dependent, ref_attr)

        Sequel.transaction(:rollback=>:nop) do
          Sequel::DB[intermediate_table_name].where(column_dependent => dependent.id).
            where(column_dependee => dependee.id).delete
        end
      end

      private_class_method(:delete_in_intermediate_table)

      def self.intermediate_table_descriptor(dependee, dependent, ref_attr)
        table_dependee = mapper_for(dependee.class).table_name_for_intermediate(dependee.class)
        table_dependent = mapper_for(dependent._type).table_name_for_intermediate(dependent._type)

        intermediate_table_name = :"#{table_dependee}_#{ref_attr}"

        column_dependee = :"#{table_dependee.to_s.singularize}_id"
        column_dependent = :"#{table_dependent.to_s.singularize}_id"
        return column_dependee, column_dependent, intermediate_table_name
      end

      private_class_method(:intermediate_table_descriptor)

      class ClassTableInheritance
        def self.insert(entity, parent_id = nil)
          entity_data = SchemaUtils::Sequel.to_row(entity, parent_id)
          entity_data.delete(:id)

          superclass_list = PersistenceService.superclass_list(entity.class)
          root_class = superclass_list.last

          rows = split_row(superclass_list, entity_data)
          rows[root_class][:_type] = PersistenceService.table_for(entity.class).to_s
          rows[root_class][:_version_id] = entity._version.id

          id = Sequel::DB[PersistenceService.table_for(root_class)].insert(rows[root_class])

          superclass_list[0..-2].reverse.each do |klazz|
            rows[klazz][:id] = id
            Sequel::DB[PersistenceService.table_for(klazz)].insert(rows[klazz])
          end

          id
        end

        def self.delete(entity)
          inheritance_root = PersistenceService.inheritance_root_for(entity.class)
          Sequel::DB[PersistenceService.table_for(inheritance_root)].where(id: entity.id).update(active: false)
        end

        def self.update(modified_entity, original_entity, already_versioned = false)
          raise Dilithium::PersistenceExceptions::ImmutableObjectError, "#{modified_entity.class} is immutable - it can't be updated" if (modified_entity.is_a? ImmutableDomainObject)

          modified_data = SchemaUtils::Sequel.to_row(modified_entity)
          original_data = SchemaUtils::Sequel.to_row(original_entity)

          unless modified_data.eql?(original_data)
            unless already_versioned
              modified_entity._version.increment!
              already_versioned = true
            end

            Sequel.verify_identifiers_unchanged(modified_entity, modified_data, original_data)

            superclass_list = PersistenceService.superclass_list(modified_entity.class)
            rows = split_row(superclass_list, modified_data)
            rows[superclass_list.last][:_type] = PersistenceService.table_for(modified_entity.class).to_s

            rows.each do |klazz, row|
              Sequel::DB[PersistenceService.table_for(klazz)].where(id: modified_entity.id).update(row)
            end

            already_versioned
          end
        end

        def self.table_name_for_intermediate(entity)
          PersistenceService.table_for(PersistenceService.inheritance_root_for(entity))
        end

        private

        def self.split_row(superclass_list, row_h)
          superclass_list.inject({}) do |memo, klazz|
            memo[klazz] = {}

            klazz.self_attributes.each do |attr|
              name = case attr
                       when BasicAttributes::ImmutableReference,
                         BasicAttributes::ChildReference,
                         BasicAttributes::ParentReference

                         SchemaUtils::Sequel.to_reference_name(attr)
                       else
                         attr.name
                     end

              memo[klazz][name] = row_h[name] if row_h.has_key?(name)
            end

            memo
          end
        end

        private_class_method(:split_row)
      end

      class LeafTableInheritance
        def self.insert(domain_object, parent_id = nil)
          mapper_strategy = SchemaUtils::Sequel::DomainObjectSchema.mapper_schema_for(domain_object.class)

          entity_data = SchemaUtils::Sequel.to_row(domain_object, parent_id)
          entity_data.delete(:id)
          entity_data.merge!(_version_id:domain_object._version.id) if mapper_strategy.needs_version?

          Sequel::DB[SchemaUtils::Sequel.to_table_name(domain_object)].insert(entity_data)
        end

        def self.delete(domain_object)
          condition = Sequel.condition_for(domain_object)
          Sequel::DB[SchemaUtils::Sequel.to_table_name(domain_object)].where(condition).update(active: false)
        end

        def self.update(modified_domain_object, original_object, already_versioned = false)
          raise Dilithium::PersistenceExceptions::ImmutableObjectError, "#{modified_domain_object.class} is immutable - it can't be updated" if (modified_domain_object.is_a? ImmutableDomainObject)

          mapper_strategy = SchemaUtils::Sequel::DomainObjectSchema.mapper_schema_for(modified_domain_object.class)
          modified_data = SchemaUtils::Sequel.to_row(modified_domain_object)
          original_data = SchemaUtils::Sequel.to_row(original_object)

          #TODO Should we even allow modification of BaseValues?
          Sequel.verify_identifiers_unchanged(modified_domain_object, modified_data, original_data)

          unless modified_data.eql?(original_data)
            if ! already_versioned && mapper_strategy.needs_version?
              modified_domain_object._version.increment!
              already_versioned = true
            end

            condition = Sequel.condition_for(modified_domain_object)
            Sequel::DB[SchemaUtils::Sequel.to_table_name(modified_domain_object)].where(condition).update(modified_data)

            already_versioned
          end
        end

        def self.table_name_for_intermediate(entity)
          PersistenceService.table_for(entity)
        end
      end
    end
  end
end