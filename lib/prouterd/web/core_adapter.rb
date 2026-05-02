module Prouterd
  module Web
    # Sole integration surface between the Web Console and the Prouterd core.
    #
    # UI code (routes, views, websocket handlers) MUST depend only on this
    # interface — never on Prouterd::Storage / ControlPlane / Runtime / Shell
    # directly. This is what lets us swap the in-process real adapter for a
    # mock during development, and what protects core invariants: writes
    # (commit, trigger, replay, cancel) go through core facades, not raw SQL.
    #
    # Concrete adapters:
    #   * Adapters::MockAdapter   — fixture data for offline UI development
    #   * Adapters::SqliteAdapter — wraps a live Prouterd SQLite database
    class CoreAdapter
      class NotImplementedYet < StandardError; end

      # ----- system / status -----
      def status; raise NotImplementedYet; end

      # ----- processes / interfaces / routes -----
      def list_processes;            raise NotImplementedYet; end
      def get_process(name);         raise NotImplementedYet; end
      def list_interfaces;           raise NotImplementedYet; end
      def get_interface(name);       raise NotImplementedYet; end
      def list_routes(process: nil); raise NotImplementedYet; end
      def list_blocks;               raise NotImplementedYet; end

      # ----- queues / policies / secrets -----
      def list_queues;               raise NotImplementedYet; end
      def list_policies;             raise NotImplementedYet; end
      def list_secrets;              raise NotImplementedYet; end

      # ----- runs -----
      def list_runs(filters = {});                       raise NotImplementedYet; end
      def count_runs(filters = {});                      raise NotImplementedYet; end
      def get_run(run_uid);                              raise NotImplementedYet; end
      def get_run_steps(run_uid);                        raise NotImplementedYet; end
      def get_step(run_uid, step_id);                    raise NotImplementedYet; end
      def get_run_context(run_uid);                      raise NotImplementedYet; end
      def get_step_context_before(run_uid, step_id);     raise NotImplementedYet; end
      def get_step_context_after(run_uid, step_id);      raise NotImplementedYet; end
      def get_step_logs(run_uid, step_id: nil, after_id: nil); raise NotImplementedYet; end
      def get_run_artifacts(run_uid, step_id: nil);      raise NotImplementedYet; end

      # ----- config -----
      def active_config;                  raise NotImplementedYet; end
      def boot_config;                    raise NotImplementedYet; end
      def draft_config(session_id: nil);  raise NotImplementedYet; end
      def config_diff(left:, right:);     raise NotImplementedYet; end
      def list_commits;                   raise NotImplementedYet; end
      def get_commit(id);                 raise NotImplementedYet; end

      # ----- actions -----
      def trigger_process(process_name, input_event);    raise NotImplementedYet; end
      def trace_event(event_json, interface_name: nil);  raise NotImplementedYet; end
      def replay_run(run_uid, from_block: nil);          raise NotImplementedYet; end
      def cancel_run(run_uid);                           raise NotImplementedYet; end
      def rollback_config(commit_id);                    raise NotImplementedYet; end
      def save_boot_config;                              raise NotImplementedYet; end

      # ----- artifact byte transfer -----
      def get_artifact(id);                              raise NotImplementedYet; end

      # ----- shell -----
      def execute_cli_command(command, session_id:); raise NotImplementedYet; end
      def cli_prompt(session_id);                    raise NotImplementedYet; end

      # ----- pub/sub (live updates) -----
      def subscribe(topic, &block);   raise NotImplementedYet; end
      def unsubscribe(subscription_id); raise NotImplementedYet; end
    end
  end
end
