require 'spec_helper'

describe Bosh::Director::VmCreator do
  subject  {Bosh::Director::VmCreator.new(cloud, logger, vm_deleter)}

  let(:cloud) { instance_double('Bosh::Cloud') }
  let(:vm_deleter) {Bosh::Director::VmDeleter.new(cloud, logger)}
  let(:agent_client) do
    instance_double(
      Bosh::Director::AgentClient,
      wait_until_ready: nil,
      update_settings: nil,
      apply: nil,
      get_state: nil
    )
  end
  let(:network_settings) { BD::DeploymentPlan::NetworkSettings.new(job.name, false, 'deployment_name', {}, [], {}, nil, 5, 'uuid-1').to_hash }
  let(:deployment) { Bosh::Director::Models::Deployment.make(name: 'deployment_name') }
  let(:deployment_plan) do
    instance_double(Bosh::Director::DeploymentPlan::Planner, model: deployment, name: 'deployment_name')
  end
  let(:availability_zone) do
    instance_double(Bosh::Director::DeploymentPlan::AvailabilityZone)
  end
  let(:vm_type) { Bosh::Director::DeploymentPlan::VmType.new({'name' => 'fake-vm-type', 'cloud_properties' => {'ram' => '2gb'}}) }
  let(:stemcell) { Bosh::Director::Models::Stemcell.make(:cid => 'stemcell-id') }
  let(:env) { Bosh::Director::DeploymentPlan::Env.new({}) }

  let(:instance) do
    instance = Bosh::Director::DeploymentPlan::Instance.new(
      job,
      5,
      'started',
      deployment_plan,
      {},
      nil,
      false,
      logger
    )
    instance.bind_existing_instance_model(instance_model)
    allow(instance).to receive(:apply_spec).and_return({})
    instance
  end
  let(:instance_plan) { BD::DeploymentPlan::InstancePlan.create_from_deployment_plan_instance(instance, logger) }

  let(:job) do
    instance_double(Bosh::Director::DeploymentPlan::Job,
      name: 'fake-job',
      vm_type: vm_type,
      stemcell: stemcell,
      env: env,
      default_network: {},
      can_run_as_errand?: false,
      deployment: deployment_plan
    )
  end
  let(:instance_model) { Bosh::Director::Models::Instance.make(uuid: SecureRandom.uuid, vm: nil, index: 5, job: 'fake-job') }

  before do
    allow(Bosh::Director::Config).to receive(:cloud).and_return(cloud)
    Bosh::Director::Config.max_vm_create_tries = 2
    allow(Bosh::Director::AgentClient).to receive(:with_vm).and_return(agent_client)
  end

  it 'should create a vm' do
    expect(cloud).to receive(:create_vm).with(
      kind_of(String), 'stemcell-id', {'ram' => '2gb'}, network_settings, ['fake-disk-cid'], {}
    ).and_return('new-vm-cid')

    expect(instance).to receive(:bind_to_vm_model)
    expect(agent_client).to receive(:wait_until_ready)
    expect(instance).to receive(:apply_vm_state)
    expect(instance).to receive(:update_trusted_certs)
    expect(instance).to receive(:update_cloud_properties!)

    subject.create_for_instance_plan(instance_plan, ['fake-disk-cid'])

    expect(Bosh::Director::Models::Vm.all.size).to eq(1)
    expect(Bosh::Director::Models::Vm.first.cid).to eq('new-vm-cid')
  end

  it 'sets vm metadata' do
    expect(cloud).to receive(:create_vm).with(
        kind_of(String), 'stemcell-id', kind_of(Hash), network_settings, ['fake-disk-cid'], {}
      ).and_return('new-vm-cid')

    allow(Bosh::Director::Config).to receive(:name).and_return('fake-director-name')

    expect(cloud).to receive(:set_vm_metadata) do |vm_cid, metadata|
      expect(vm_cid).to eq('new-vm-cid')
      expect(metadata).to match({
        deployment: 'deployment_name',
        job: 'fake-job',
        index: '5',
        director: 'fake-director-name',
        id: instance_model.uuid
      })
    end

    subject.create_for_instance_plan(instance_plan, ['fake-disk-cid'])
  end

  it 'should create credentials when encryption is enabled' do
    Bosh::Director::Config.encryption = true
    expect(cloud).to receive(:create_vm).with(kind_of(String), 'stemcell-id',
                                           kind_of(Hash), network_settings, ['fake-disk-cid'],
                                           {'bosh' =>
                                             { 'credentials' =>
                                               { 'crypt_key' => kind_of(String),
                                                 'sign_key' => kind_of(String)}}})

    subject.create_for_instance_plan(instance_plan, ['fake-disk-cid'])

    expect(Bosh::Director::Models::Vm.all.size).to eq(1)
    vm = Bosh::Director::Models::Vm.first

    expect(Base64.strict_decode64(vm.credentials['crypt_key'])).to be_kind_of(String)
    expect(Base64.strict_decode64(vm.credentials['sign_key'])).to be_kind_of(String)

    expect {
      Base64.strict_decode64(vm.credentials['crypt_key'] + 'foobar')
    }.to raise_error(ArgumentError, /invalid base64/)

    expect {
      Base64.strict_decode64(vm.credentials['sign_key'] + 'barbaz')
    }.to raise_error(ArgumentError, /invalid base64/)
  end

  it 'should retry creating a VM if it is told it is a retryable error' do
    expect(cloud).to receive(:create_vm).once.and_raise(Bosh::Clouds::VMCreationFailed.new(true))
    expect(cloud).to receive(:create_vm).once.and_return('fake-vm-cid')

    subject.create_for_instance_plan(instance_plan, ['fake-disk-cid'])

    expect(Bosh::Director::Models::Vm.first.cid).to eq('fake-vm-cid')
  end

  it 'should not retry creating a VM if it is told it is not a retryable error' do
    expect(cloud).to receive(:create_vm).once.and_raise(Bosh::Clouds::VMCreationFailed.new(false))

    expect {
      subject.create_for_instance_plan(instance_plan, ['fake-disk-cid'])
    }.to raise_error(Bosh::Clouds::VMCreationFailed)
  end

  it 'should try exactly the configured number of times (max_vm_create_tries) when it is a retryable error' do
    Bosh::Director::Config.max_vm_create_tries = 3

    expect(cloud).to receive(:create_vm).exactly(3).times.and_raise(Bosh::Clouds::VMCreationFailed.new(true))

    expect {
      subject.create_for_instance_plan(instance_plan, ['fake-disk-cid'])
    }.to raise_error(Bosh::Clouds::VMCreationFailed)
  end

  it 'should have deep copy of environment' do
    Bosh::Director::Config.encryption = true
    env_id = nil

    expect(cloud).to receive(:create_vm) do |*args|
      env_id = args[5].object_id
    end

    subject.create_for_instance_plan(instance_plan, ['fake-disk-cid'])

    expect(cloud).to receive(:create_vm) do |*args|
      expect(args[5].object_id).not_to eq(env_id)
    end

    subject.create_for_instance_plan(instance_plan, ['fake-disk-cid'])
  end
end
