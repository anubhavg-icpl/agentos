"""A retried isolated task must be able to recreate its worktree and branch."""
import os
import time

from orchfix import cfg, clock, orch, runtime, submit, systemctl, taskstore  # noqa: F401
from test_taskrunner import env, queue  # noqa: F401


def test_retry_of_an_isolated_task_starts_from_a_clean_worktree(env, orch):
    tid = queue(orch, prompt="fail", isolate=True, max_retries=1, backoff_sec=0)
    assert env.runner.run(tid) == 1
    first = orch.tasks.get(tid)
    assert first["status"] == "queued" and first["attempt"] == 2          # re-queued, not failed
    wt = "%s.%s" % (env.ws, tid)
    open(os.path.join(wt, "leftover.txt"), "w").write("from attempt 1")
    # the orchestrator dispatches the retry again
    orch.tasks.update(tid, lambda t: t.update(status="running", started_at=time.time()) or True)
    assert env.runner.run(tid) == 1
    final = orch.tasks.get(tid)
    assert final["status"] == "failed" and [a["attempt"] for a in final["attempts"]] == [1, 2]
    assert "setup failed" not in str(final["result"].get("error"))        # the worktree was recreated
    assert not os.path.exists(os.path.join(wt, "leftover.txt"))
