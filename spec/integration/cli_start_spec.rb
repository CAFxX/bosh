require 'spec_helper'

describe 'start job', type: :integration do
  with_reset_sandbox_before_each

  it 'starts a job instance only' do
    deploy_from_scratch
    expect(director.vms.map(&:last_known_state).uniq).to match_array(['running'])
    bosh_runner.run('stop')
    expect(director.vms.map(&:last_known_state).uniq).to match_array(['stopped'])

    expect(bosh_runner.run('start foobar 0')).to match %r{foobar/0 started}
    vms_after_instance_started = director.vms
    vm_was_started = vm(vms_after_instance_started, "foobar/0")
    expect(vm_was_started.last_known_state).to eq ('running')
    expect((vms_after_instance_started -[vm_was_started]).map(&:last_known_state).uniq).to match_array(['stopped'])
  end

  it 'starts vms for a given job / the whole deployment' do
      manifest_hash = Bosh::Spec::Deployments.simple_manifest
      manifest_hash['jobs']<< {
          'name' => 'another-job',
          'template' => 'foobar',
          'resource_pool' => 'a',
          'instances' => 1,
          'networks' => [{'name' => 'a'}],
      }
      manifest_hash['jobs'].first['instances']= 2
      deploy_from_scratch(manifest_hash: manifest_hash)
      bosh_runner.run('stop')
      expect(director.vms.map(&:last_known_state).uniq).to match_array(['stopped'])

      #only vms for one job should be started
      expect(bosh_runner.run('start foobar')).to match %r{foobar/\* started}
      vms_after_job_start = director.vms
      expect(vm(vms_after_job_start, "foobar/0").last_known_state).to eq('running')
      expect(vm(vms_after_job_start, "foobar/1").last_known_state).to eq('running')
      expect(vm(vms_after_job_start, "another-job/0").last_known_state).to eq('stopped')

      #all vms should be started
      bosh_runner.run('stop')
      expect(director.vms.map(&:last_known_state).uniq).to match_array(['stopped'])
      expect(bosh_runner.run('start')).to match %r{all jobs started}
      expect(director.vms.map(&:last_known_state).uniq).to match_array(['running'])
    end


  def vm(vms, job_name_index)
    vm = vms.detect { |vm| vm.job_name_index == job_name_index }
    vm || raise("Failed to find vm #{job_name_index}")
  end
end
