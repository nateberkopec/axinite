class Account < ActiveForce::SObject
  self.table_name = 'Account'
  field :amount, from: 'Amount'
  has_many :contacts, model: 'Contact', foreign_key: :account_id
  has_one :primary_contact, model: 'Contact', foreign_key: :account_id, relationship_name: 'Contacts'

  def self.exercise(operation)
    case operation
    when 'contacts', 'primary_contact'
      all.map { |owner| Array(owner.public_send(operation)).map(&:id) }
    when 'contacts_fixed', 'primary_contact_fixed'
      association = operation.delete_suffix('_fixed').to_sym
      includes(association).map { |owner| Array(owner.public_send(association)).map(&:id) }
    when 'belongs_to'
      Contact.all.map { |child| child.account.id }
    when 'belongs_to_fixed'
      Contact.includes(:account).map { |child| child.account.id }
    when 'lookup'
      %w[a1 a2].map { |id| where(id: id).map(&:id) }
    when 'count', 'sum'
      %w[a1 a2].map { |id| where(id: id).public_send(operation, *(operation == 'sum' ? [:amount] : [])) }
    when 'count_fixed', 'sum_fixed'
      where(id: %w[a1 a2]).public_send(operation.delete_suffix('_fixed'), *(operation == 'sum_fixed' ? [:amount] : []))
    when 'error'
      exercise('lookup')
      raise ArgumentError, 'original application failure'
    when 'bulk'
      where(id: %w[a1 a2]).map(&:id)
    else
      raise ArgumentError, 'unknown fixture operation'
    end
  end
end
