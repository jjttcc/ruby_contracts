require "ruby_contracts/version"

module Contracts
  class Error < Exception ; end

  # When it is used with @__contracts_for:
  #   before key must contain a disjunction of conjunction with preconditions
  #   after key must contain a conjunction with postconditions
  #
  # When it is used with @__contracts:
  #   before key must contain a conjunction
  #   after key must contain a conjunction
  def self.empty_contracts
    {:before => [], :after => []}
  end

  module DSL
    def self.included(base)
      base.extend Contracts::DSL::ClassMethods
      base.__contracts_initialize
    end

    module ClassMethods
      def inherited(subclass)
        super
        subclass.__contracts_initialize
      end

      def __contracts_initialize
        @__contracts = Contracts.empty_contracts
        @__contracts_for = {}
      end

      def __contracts_for(name, current_contracts=nil)
        inherited_contracts = ancestors[1..-1].reduce(Contracts.empty_contracts) do |c, klass|
          ancestor_hash = klass.instance_variable_get('@__contracts_for') || {}
          c[:before] << ancestor_hash[name][:before] if ancestor_hash.has_key?(name)
          c[:after] += ancestor_hash[name][:after] if ancestor_hash.has_key?(name)
          c
        end

        if current_contracts
          inherited_contracts[:before] << current_contracts[:before] unless current_contracts[:before].empty?
          inherited_contracts[:after] += current_contracts[:after] unless current_contracts[:after].empty?
        end

        inherited_contracts
      end

      def __contract_failure!(name, message, result, *args)
        args.pop if args.last.kind_of?(Proc)
        raise Contracts::Error.new("#{self}##{name}(#{args.join ', '}) => #{result || "?"} ; #{message}.")
      end

      def type(options)
        @__contracts[:before] << [:type, options[:in]] if ENV['ENABLE_ASSERTION'] && options.has_key?(:in)
        @__contracts[:after] << [:type, options[:out]] if ENV['ENABLE_ASSERTION'] && options.has_key?(:out)
      end

      def pre(message=nil, &block)
        @__contracts[:before] << [:params, message, block] if ENV['ENABLE_ASSERTION']
      end

      def post(message=nil, &block)
        @__contracts[:after] << [:result, message, block] if ENV['ENABLE_ASSERTION']
      end

      def method_added(name)
        super

        return unless ENV['ENABLE_ASSERTION']
        return if @__skip_other_contracts_definitions
        return if @__contracts_for.has_key?(name)

        __contracts = @__contracts_for[name] ||= __contracts_for(name, @__contracts)
        @__contracts = Contracts.empty_contracts

        if !__contracts[:before].empty? || !__contracts[:after].empty?
          @__skip_other_contracts_definitions = true
          original_method_name = "#{name}__with_contracts"
          define_method(original_method_name, instance_method(name))

          count = 0
          before_contracts = __contracts[:before].reduce("__before_contracts_disjunction = []\n") do |code, contracts_disjunction|
            contracts_conjunction = contracts_disjunction.reduce("__before_contracts_conjunction = []\n") do |code, contract|
              type, *args = contract
              case type
              when :type
                classes = args[0]
                code << "if __args.size < #{classes.size} then\n"
                code << "  __before_contracts_conjunction << ['#{name}', \"need at least #{classes.size} arguments (%i given)\" % [__args.size], nil, *args]\n"
                code << "else\n"
                conditions = []
                classes.each_with_index{ |klass, i| conditions << "__args[#{i}].kind_of?(#{klass})" }
                code << "  if !(#{conditions.join(' && ')}) then\n"
                code << "    __before_contracts_conjunction << ['#{name}', 'input type error', nil, *__args]\n"
                code << "  end\n"
                code << "end\n"
                code

              when :params
                # Define a method that verify the assertion
                contract_method_name = "__verify_contract_#{name}_in_#{count = count + 1}"
                define_method(contract_method_name) { |*params| self.instance_exec(*params, &args[1]) }

                code << "if !#{contract_method_name}(*__args) then\n"
                code << "  __before_contracts_conjunction << ['#{name}', \"invalid precondition: #{args[0]}\", nil, *__args]\n"
                code << "end\n"
                code
              else
                code
              end
            end
            code << contracts_conjunction
            code << "__before_contracts_disjunction << __before_contracts_conjunction\n"
            code
          end
          before_contracts << "if __before_contracts_disjunction.any?{|conj| !conj.empty?} then\n"
          before_contracts << "  self.class.__contract_failure!(*__before_contracts_disjunction.first.first)\n"
          before_contracts << "end\n"

          after_contracts = __contracts[:after].reduce("") do |code, contract|
            type, *args = contract
            case type
            when :type
              code << "if !result.kind_of?(#{args[0]}) then\n"
              code << "self.class.__contract_failure!(name, \"result must be a kind of '#{args[0]}' not '%s'\" % [result.class.to_s], result, *__args)\n"
              code << "end\n"
              code
            when :result
              # Define a method that verify the assertion
              contract_method_name = "__verify_contract_#{name}_out_#{count = count + 1}"
              define_method(contract_method_name) { |*params| self.instance_exec(*params, &args[1]) }

              code << "if !#{contract_method_name}(result, *__args) then\n"
              code << "  self.class.__contract_failure!('#{name}', \"invalid postcondition: #{args[0]}\", result, *__args)\n"
              code << "end\n"
              code
            else
              code
            end
          end

          method = <<-EOM
            def #{name}(*args, &block)
              __args = block.nil? ? args : args + [block]
              #{before_contracts}
              result = #{original_method_name}(*args, &block)
              #{after_contracts}
              return result
            end
          EOM

          class_eval method

          @__skip_other_contracts_definitions = false
        end
      end
    end
  end
end
