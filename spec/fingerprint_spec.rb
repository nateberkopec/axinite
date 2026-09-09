require 'spec_helper'

RSpec.describe Axinite::Fingerprint do
  def fingerprint(value)
    described_class.call(value)
  end

  [
    ["Name = 'D\\'Angelo'", "Name = 'Other'"],
    ["Name = 'back\\\\slash'", "Name = 'Other'"],
    ['Amount IN (USD100, USD200.50)', 'Amount IN (USD300)'],
    ['Amount > USD100', 'Amount > USD200'],
    ['Amount >= USD100.50', 'Amount >= USD200.75'],
    ['Amount > -12.50e+2', 'Amount > +0.4'],
    ['CreatedDate > 2025-01-01T01:02:03.123Z', 'CreatedDate > 2026-02-02T02:03:04+02:00'],
    ['Date__c = 2025-01-01', 'Date__c = 2026-02-02'],
    ['CreatedDate = LAST_N_DAYS:10', 'CreatedDate = NEXT_N_DAYS:20'],
    ['CreatedDate = N_DAYS_AGO:10', 'CreatedDate = TODAY'],
    ["Id IN ('a', 'b')", "Id IN ('c')"],
    ['Flag__c = TRUE', 'Flag__c = FALSE'],
    ['SELECT Field2__c FROM Object1__c', " select  Field2__c\nfrom Object1__c "]
  ].each do |left, right|
    it "normalizes #{left}" do
      expect(fingerprint(left)).to eq(fingerprint(right))
    end
  end

  it 'does not normalize identifier suffixes as relative dates' do
    expect(fingerprint('SELECT CustomToday, Field2__c FROM Account')).to eq('select customtoday , field2__c from account')
  end

  it 'retains currency codes' do
    expect(fingerprint('Amount > USD100')).not_to eq(fingerprint('Amount > EUR100'))
  end

  it 'retains distinct and mixed currencies in IN lists' do
    expect(fingerprint('Amount IN (USD100)')).not_to eq(fingerprint('Amount IN (EUR100)'))
    expect(fingerprint('Amount IN (USD100, EUR200)')).to eq('amount in ( usd? , eur? )')
  end

  it 'does not treat subqueries or function arguments as currency literal lists' do
    expect(fingerprint('Id IN (SELECT USD100 FROM Account)')).to eq('id in ( select usd100 from account )')
    expect(fingerprint('SELECT FORMAT(USD100), SUM(EUR200) USD300 FROM Account')).to eq(
      'select format ( usd100 ) , sum ( eur200 ) usd300 from account'
    )
    expect(fingerprint('Id IN (USD100__c, USD200__c)')).to eq('id in ( usd100__c , usd200__c )')
  end

  it 'preserves currency-like field names, aliases and identifier suffixes' do
    expect(fingerprint('SELECT USD100, SUM(Amount) EUR200 FROM USD300 WHERE USD400 > USD500__c')).to eq(
      'select usd100 , sum ( amount ) eur200 from usd300 where usd400 > usd500__c'
    )
  end

  it 'preserves digits in identifiers' do
    expect(fingerprint('SELECT Field2__c FROM Object1__c')).not_to eq(fingerprint('SELECT Field3__c FROM Object2__c'))
  end

  it 'retains relationship and semi-join subqueries' do
    query = "SELECT Id, (SELECT Id FROM Contacts WHERE Name = 'fake') FROM Account WHERE Id IN (SELECT AccountId FROM Contact WHERE Age__c > 2)"
    result = fingerprint(query)
    expect(result).to include('in ( select accountid from contact')
    expect(result).to include('( select id from contacts where name = ? )')
    expect(result).not_to eq(fingerprint("SELECT Id FROM Account WHERE Id IN ('fake')"))
  end

  it 'does not interpret literals as structural syntax or comments' do
    expect(fingerprint("Name = 'IN (1,2) -- SELECT 2025-01-01' AND Field2__c = 10")).to eq('name = ? and field2__c = ?')
  end
end
