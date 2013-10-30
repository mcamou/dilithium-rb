require_relative 'database_utils'

class EntitySerializer

  def self.to_hash(entity)
    h = {}

    case entity
    when Association::ReferenceEntity
      h[:"#{entity.type.to_s.split('::').last.downcase.singularize}_id"] = entity.id
    when Association::ResolvedEntity
      h = entity.marshal_dump
    else
      entity.instance_variables.each do |attr|
        attr_name = attr.to_s[1..-1].to_sym
        attr_value = entity.instance_variable_get(attr)
        # TODO: uncomment when BasicEntityBuilder is ready
        # attr_type = entity.class.class_variable_get(:'@@attributes')[attr_name]
        # attr_value = attr_type.to_generic_type(attr_value) if attr_type.instance_of?(BasicAttributes::ExtendedGenericAttribute)
        h[attr_name] =  attr_value
      end
    end
    h
  end

  def self.to_nested_hash(entity)
    entity_h = to_hash(entity)

    entity_h.each do |attr, value|

      unless entity.is_a?(Association::ReferenceEntity)
        attr_type = entity.class.class_variable_get(:'@@attributes')[attr]

        case attr_type
          when BasicAttributes::ChildReference, BasicAttributes::MultiReference
            entity_h[attr] = Array.new
            value.each do |ref|
              entity_h[attr] << to_nested_hash(ref)
            end
          when BasicAttributes::EntityReference
            entity_h[attr] = to_nested_hash(value) unless value.nil?
          when BasicAttributes::ParentReference
            entity_h.delete(attr)
        end
      end

    end

    entity_h
  end

  def self.to_row(entity, parent_id=nil)
    row = {}
    entity_h = to_hash(entity)
    if parent_id
      parent_ref = "#{entity.class.parent_reference}_id".to_sym
      entity_h[parent_ref] = parent_id if parent_id
    end
    entity_h.each do |attr,value|
      attr_type = entity.class.class_variable_get(:'@@attributes')[attr]
      unless [BasicAttributes::ChildReference, BasicAttributes::ParentReference,
              BasicAttributes::MultiReference].include?(attr_type.class)
        if attr_type.is_a?(BasicAttributes::EntityReference)
          row[DatabaseUtils.to_reference_name(attr_type)] = value.nil? ? attr_type.default : value.id
        else
          row[attr] = value
        end
      end
    end
    row
  end

end