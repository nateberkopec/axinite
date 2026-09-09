require 'strscan'

module Axinite
  # SOQL tokens, not SQL text substitutions: digits inside names stay intact.
  module Fingerprint
    RELATIVE_DATE = /\A(?:YESTERDAY|TODAY|TOMORROW|(?:LAST|THIS|NEXT)_(?:WEEK|MONTH|QUARTER|YEAR|FISCAL_QUARTER|FISCAL_YEAR)|(?:LAST|NEXT)_90_DAYS|N_(?:DAYS|WEEKS|MONTHS|QUARTERS|YEARS|FISCAL_QUARTERS|FISCAL_YEARS)_AGO|(?:LAST|NEXT)_N_(?:DAYS|WEEKS|MONTHS|QUARTERS|YEARS|FISCAL_QUARTERS|FISCAL_YEARS))\z/i

    def self.call(soql)
      scanner = StringScanner.new(soql)
      tokens = []
      until scanner.eos?
        if scanner.scan(/\s+/)
          next
        elsif scanner.scan(/'(?:\\.|[^'\\])*'/m)
          tokens << '?'
        elsif scanner.scan(/\d{4}-\d{2}-\d{2}(?:T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:\d{2}))?(?![\w])/i)
          tokens << '?'
        elsif (name = scanner.scan(/[a-z_][a-z_0-9]*/i))
          if RELATIVE_DATE.match?(name)
            scanner.scan(/:\d+/)
            tokens << '?'
          else
            tokens << (%w[true false null].include?(name.downcase) ? '?' : name.downcase)
          end
        elsif scanner.scan(/[+-]?(?:\d+(?:\.\d*)?|\.\d+)(?:e[+-]?\d+)?/i)
          tokens << '?'
        else
          tokens << scanner.getch
        end
      end
      # Only literal IN lists collapse; nested SELECTs retain their structure.
      tokens.join(' ').gsub(/\bin \( \?(?: , \?)* \)/, 'in ( ?+ )')
    end
  end
end
