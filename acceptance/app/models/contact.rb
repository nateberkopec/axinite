class Contact < ActiveForce::SObject
  self.table_name = 'Contact'
  field :account_id, from: 'AccountId'
  belongs_to :account, model: Account, foreign_key: :account_id
end
