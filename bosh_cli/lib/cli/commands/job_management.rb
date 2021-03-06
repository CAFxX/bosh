# Copyright (c) 2009-2012 VMware, Inc.
require 'cli/job_state'

module Bosh::Cli
  module Command
    class JobManagement < Base
      FORCE = 'Proceed even when there are other manifest changes'
      SKIP_DRAIN = 'Skip running drain script'

      # bosh start
      usage 'start'
      desc 'Start all jobs/job/instance'
      option '--force', FORCE
      def start_job(job = '*', index = nil)
        change_job_state(:start, job, index)
      end

      # bosh stop
      usage 'stop'
      desc 'Stop all jobs/job/instance'
      option '--soft', 'Stop process only'
      option '--hard', 'Power off VM'
      option '--force', FORCE
      option '--skip-drain', SKIP_DRAIN
      def stop_job(job = '*', index = nil)
        if hard?
          change_job_state(:detach, job, index)
        else
          change_job_state(:stop, job, index)
        end
      end

      # bosh restart
      usage 'restart'
      desc 'Restart all jobs/job/instance (soft stop + start)'
      option '--force', FORCE
      option '--skip-drain', SKIP_DRAIN
      def restart_job(job = '*', index = nil)
        change_job_state(:restart, job, index)
      end

      # bosh recreate
      usage 'recreate'
      desc 'Recreate all jobs/job/instance (hard stop + start)'
      option '--force', FORCE
      option '--skip-drain', SKIP_DRAIN
      def recreate_job(job = '*', index = nil)
        change_job_state(:recreate, job, index)
      end

      private

      def change_job_state(state, job, index = nil)
        auth_required
        manifest = parse_manifest(state)
        job_state = JobState.new(self, manifest, skip_drain: skip_drain?)
        status, task_id, completion_desc = job_state.change(state, job, index, force?)
        task_report(status, task_id, completion_desc)
      end

      def hard?
        !!options[:hard]
      end

      def soft?
        !!options[:soft]
      end

      def force?
        !!options[:force]
      end

      def skip_drain?
        !!options[:skip_drain]
      end

      def parse_manifest(operation)
        manifest = prepare_deployment_manifest(show_state: true)

        if hard? && soft?
          err('Cannot handle both --hard and --soft options, please choose one')
        end

        if !hard_and_soft_options_allowed?(operation) && (hard? || soft?)
          err("--hard and --soft options only make sense for `stop' operation")
        end

        manifest
      end

      def hard_and_soft_options_allowed?(operation)
        operation == :stop || operation == :detach
      end
    end
  end
end
