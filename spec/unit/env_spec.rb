# coding: UTF-8

require "spec_helper"
require "vcap/common"
require "dea/env"
require "dea/starting/start_message"
require "dea/staging/staging_message"

describe Dea::Env do
  let(:strategy) do
    double("strategy",
           vcap_application: {"fake vcap_application key" => "fake vcap_application value"},
           message: start_message,
           system_environment_variables: [%w(fake_key fake_value)]
    )
  end

  let(:strategy_chooser) { double("strategy chooser", strategy: strategy) }

  let(:env_exporter) { Dea::Env::Exporter }

  let(:service) do
    {
      "credentials" => {"uri" => "postgres://user:pass@host:5432/db"},
      "label" => "elephantsql-n/a",
      "plan" => "panda",
      "plan_option" => "plan_option",
      "name" => "elephantsql-vip-uat",
      "tags" => {"key" => "value"},
      "syslog_drain_url" => "syslog://drain-url.example.com:514",
      "blacklisted" => "blacklisted"
    }
  end

  let(:services) { [service] }

  let(:user_provided_environment) { ["fake_user_provided_key=fake_user_provided_value"] }

  let(:instance) do
    attributes = {"instance_id" => VCAP.secure_uuid}
    double(:instance, attributes: attributes, instance_container_port: 4567, state_starting_timestamp: Time.now.to_f)
  end

  let(:start_message) do
    StartMessage.new(
      "services" => services,
      "limits" => {
        "mem" => 512,
      },
      "vcap_application" => start_message_vcap_application,
      "env" => user_provided_environment,
    )
  end

  let(:start_message_vcap_application) { { "message vcap_application key" => "message vcap_application value" } }

  subject(:env) { Dea::Env.new(start_message, instance, env_exporter, strategy_chooser) }

  describe "#vcap_services" do
    let(:vcap_services) { env.send(:vcap_services) }

    keys = %W(
        name
        label
        tags
        plan
        plan_option
        credentials
        syslog_drain_url
      )

    keys.each do |key|
      it "includes #{key.inspect}" do
        vcap_services[service["label"]].first.should include(key)
      end
    end

    it "doesn't include unknown keys" do
      expect(service).to have_key("blacklisted")
      vcap_services[service["label"]].first.keys.should_not include("blacklisted")
    end

    describe "grouping" do
      let(:services) do
        [
          service.merge("label" => "l1"),
          service.merge("label" => "l1"),
          service.merge("label" => "l2"),
        ]
      end

      it "should group services by label" do
        vcap_services.should have(2).groups
        vcap_services["l1"].should have(2).services
        vcap_services["l2"].should have(1).service
      end
    end

    describe "ignoring" do
      let(:services) do
        [service.merge("name" => nil)]
      end

      it "should ignore keys with nil values" do
        vcap_services[service["label"]].should have(1).service
        vcap_services[service["label"]].first.keys.should_not include("name")
      end
    end
  end

  describe "#exported_system_environment_variables" do
    let(:exported_system_vars) { env.exported_system_environment_variables }
    let(:evaluated_system_vars) { `#{exported_system_vars} env` }

    it "includes the system_environment_variables from the strategy" do
      evaluated_system_vars.should include("fake_key=fake_value")
    end

    it "exports MEMORY_LIMIT" do
      evaluated_system_vars.should include("MEMORY_LIMIT=512m")
    end

    it "exports VCAP_APPLICATION containing strategy vcap_application" do
      evaluated_system_vars.should match('VCAP_APPLICATION={.*"fake vcap_application key":"fake vcap_application value".*}')
    end

    it "exports VCAP_APPLICATION containing message vcap_application" do
      evaluated_system_vars.should match('VCAP_APPLICATION={.*"message vcap_application key":"message vcap_application value".*}')
    end

    it "exports VCAP_SERVICES" do
      evaluated_system_vars.should match('VCAP_SERVICES={.*"plan":"panda".*}')
    end

    context "when it has a DB" do
      it "exports DATABASE_URL" do
        evaluated_system_vars.should include("DATABASE_URL=postgres://user:pass@host:5432/db")
      end
    end

    context "when it does NOT have a DB" do
      let(:services) { [] }

      it "does not export DATABASE_URL" do
        evaluated_system_vars.should_not include("DATABASE_URL")
      end
    end

    describe "escaping" do
      describe "VCAP_SERVICES" do
        context "when VCAP_SERVICES contains back-references ($)" do
          let(:services) { [ service.merge("label" => "p@nda$arecool") ] }
          it "escapes the back-references so that they are not evaluated" do
            evaluated_system_vars.should include("p@nda$arecool")
          end
        end

        context "when VCAP_SERVICES contains backticks (`)" do
          let(:services) { [ service.merge("label" => "p`ndasarecool") ] }
          it "escapes the backticks so that they are not evaluated" do
            evaluated_system_vars.should include("p`ndasarecool")
          end
        end

        context "when VCAP_SERVICES contains single quotes (')" do
          let(:services) { [ service.merge("label" => "p'ndasarecool") ] }
          it "escapes the single quotes so that they are not evaluated" do
            evaluated_system_vars.should include("p'ndasarecool")
          end
        end
      end

      describe "VCAP_APPLICATION" do
        context "when VCAP_APPLICATION contains back-references ($)" do
          let(:start_message_vcap_application) { { foo: "p@nda$arecool" } }
          it "escapes the back-references so that they are not evaluated" do
            evaluated_system_vars.should include("p@nda$arecool")
          end
        end

        context "when VCAP_APPLICATION contains backticks (`)" do
          let(:start_message_vcap_application) { { foo: "p`nda`arecool" } }
          it "escapes the backticks so that they are not evaluated" do
            evaluated_system_vars.should include("p`nda`arecool")
          end
        end

        context "when VCAP_APPLICATION contains single quotes (')" do
          let(:start_message_vcap_application) { { foo: "p'ndasarecool" } }
          it "escapes the single quotes so that they are not evaluated" do
            evaluated_system_vars.should include("p'ndasarecool")
          end
        end
      end
    end
  end

  describe "#exported_user_environment_variables" do
    let(:exported_variables) { env.exported_user_environment_variables }
    let(:evaluated_user_vars) { `#{exported_variables} env` }

    it "includes the user defined variables" do
      exported_variables.should include("fake_user_provided_key=\"fake_user_provided_value\"")
    end

    describe "escaping" do
      describe "when user environment variables refer to other variables" do
        let(:user_provided_environment) { ["foo=bar", "backref=$foo"] }
        it "does not escape user provided variables, and therefore expands backreferences" do
          evaluated_user_vars.should include("backref=bar")
        end
      end
    end
  end

  describe "exported_environment_variables" do
    subject(:env) { Dea::Env.new(start_message, instance, env_exporter) }

    let(:user_provided_environment) { ["PORT=stupid idea"] }
    let(:evaluated_environment) { `#{env.exported_environment_variables} env` }

    it "exports PORT" do
      env.exported_environment_variables.should include('PORT="stupid idea"')
    end

    describe "escaping" do
      let(:services) { [ service.merge('label' => 'p@nda$s') ] }
      let(:user_provided_environment) { ["foo=bar", "backref=$foo"] }

      it "escapes system variables" do
        evaluated_environment.should include('"label":"p@nda$s"')
      end

      it "does not escape user variables" do
        evaluated_environment.should include("backref=bar")
      end
    end
  end
end
