require 'shellwords'

module Dea
  class Env
    class Exporter < Struct.new(:variables)
      def export
        variables.map do |(key, value)|
          %Q{export %s="%s";\n} % [key, value.to_s.gsub('"', '\"')]
        end.join
      end

      def export_escaped
        variables.map do |(key, value)|
          %Q{export %s=%s;\n} % [key, value.to_s.shellescape]
        end.join
      end
    end
  end
end
