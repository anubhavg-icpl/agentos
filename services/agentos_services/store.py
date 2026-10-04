"""Redis-backed state shared by the gateway, the daemon and the CLIs.

Spend is kept per UTC day in dated keys, so "daily" budgets reset without a
cron job and old days expire on their own.

Keys (all prefixed with "agentos:"):
  spend:<date>:agent:<id>      float   USD spent by one agent
  spend:<date>:global          float   USD spent by all agents
  spend:<date>:model:<model>   float   USD spent per model
  resv:<date>:agent:<id>       hash    in-flight budget reservations: <rid> -> "<usd>:<deadline>"
  resv:<date>:global           hash    the same, for all agents
  tokens:<date>:agent:<id>     hash    token counters + request count
  requests:<date>:agent:<id>   hash    responses by status class (2xx, 4xx...)
  budget:agent:<id>            float   per-agent daily budget override
  alerts:<date>:agent:<id>     set     thresholds already alerted today
  rate:<id>:<minute>           int     requests in the current minute
  cb:failures:<id>             int     consecutive upstream failures
  cb:open:<id>                 float   unix time until which the circuit is open
  loop:<id>                    hash    fingerprint of the last request + run length
  record:<id>                  "1"     record this agent's requests (in addition to the global flag)
  replay:<id>                  hash    recording being replayed, position, total
  bus:<topic>                  stream  inter-agent messages (bounded length)
Events are published on the "agentos:events" channel as JSON.
"""

import json
import logging
import time
import uuid

import redis

log = logging.getLogger("agentos.store")

PREFIX = "agentos:"
EVENTS_CHANNEL = PREFIX + "events"
DAY_TTL = 35 * 24 * 3600


def utc_date(ts=None):
    return time.strftime("%Y-%m-%d", time.gmtime(ts if ts is not None else time.time()))


def connect(url):
    return redis.Redis.from_url(url, decode_responses=True)


class Reservation:
    """An amount of budget held for one in-flight request.

    `release()` is idempotent and never raises: a reservation that cannot be
    released (Redis down) expires on its own at its deadline.
    """

    def __init__(self, store=None, keys=(), rid=None, usd=0.0):
        self.store = store
        self.keys = keys
        self.rid = rid
        self.usd = usd
        self.released = store is None

    def release(self):
        if self.released:
            return
        self.released = True
        try:
            self.store.r.hdel(self.keys[0], self.rid)
            self.store.r.hdel(self.keys[1], self.rid)
        except redis.RedisError as exc:
            log.warning("cannot release budget reservation %s: %s", self.rid, exc)


class BudgetRefused(Exception):
    def __init__(self, scope, spent, reserved, limit):
        super().__init__(scope)
        self.scope, self.spent, self.reserved, self.limit = scope, spent, reserved, limit


class Store:
    def __init__(self, client, clock=time.time):
        self.r = client
        self.clock = clock

    def _k(self, *parts):
        return PREFIX + ":".join(str(p) for p in parts)

    # ── spend & budgets ────────────────────────────────────────────────
    def spend(self, agent, date=None):
        return float(self.r.get(self._k("spend", date or utc_date(self.clock()), "agent", agent)) or 0.0)

    def global_spend(self, date=None):
        return float(self.r.get(self._k("spend", date or utc_date(self.clock()), "global")) or 0.0)

    def limit(self, agent, default):
        value = self.r.get(self._k("budget", "agent", agent))
        return float(value) if value is not None else float(default)

    def set_limit(self, agent, usd):
        self.r.set(self._k("budget", "agent", agent), repr(float(usd)))

    def clear_limit(self, agent):
        self.r.delete(self._k("budget", "agent", agent))

    @staticmethod
    def _live(entries, now):
        """Split a reservation hash into (live total, expired ids)."""
        total, dead = 0.0, []
        for rid, value in entries.items():
            usd, _, deadline = value.partition(":")
            if float(deadline or 0) < now:
                dead.append(rid)
            else:
                total += float(usd)
        return total, dead

    def reserve(self, agent, usd, agent_limit, global_limit, hold_sec=900):
        """Atomically hold `usd` against the agent's and the global daily budget.

        The check and the hold happen in one WATCH/MULTI transaction, so
        concurrent requests cannot all pass a check that only one of them
        fits. Refuses (BudgetRefused) when spend + holds + usd would exceed a
        limit; a request that needs no budget (usd == 0) is refused only when
        the limit is already spent. Raises redis.RedisError when Redis fails.
        """
        date = utc_date(self.clock())
        spend_keys = (self._k("spend", date, "agent", agent), self._k("spend", date, "global"))
        hold_keys = (self._k("resv", date, "agent", agent), self._k("resv", date, "global"))
        rid = uuid.uuid4().hex

        def txn(pipe):
            now = self.clock()
            spent = [float(pipe.get(k) or 0.0) for k in spend_keys]
            held, dead = [], []
            for k in hold_keys:
                total, gone = self._live(pipe.hgetall(k), now)
                held.append(total)
                dead.append(gone)
            for scope, i, limit in (("agent", 0, agent_limit), ("global", 1, global_limit)):
                over = spent[i] >= limit if usd <= 0 else spent[i] + held[i] + usd > limit
                if over:
                    raise BudgetRefused(scope, spent[i], held[i], limit)
            pipe.multi()
            for i, k in enumerate(hold_keys):
                if dead[i]:
                    pipe.hdel(k, *dead[i])
                if usd > 0:
                    pipe.hset(k, rid, "%r:%r" % (float(usd), now + hold_sec))
                    pipe.expire(k, DAY_TTL)

        self.r.transaction(txn, *spend_keys, *hold_keys)
        return Reservation(self if usd > 0 else None, hold_keys, rid, usd)

    def reserved(self, agent=None, date=None):
        """USD currently held by in-flight requests (one agent, or all)."""
        date = date or utc_date(self.clock())
        key = self._k("resv", date, "agent", agent) if agent else self._k("resv", date, "global")
        return self._live(self.r.hgetall(key), self.clock())[0]

    def record(self, agent, model, usd, usage):
        """Add one request's cost and tokens. Returns (agent_total, global_total)."""
        date = utc_date(self.clock())
        agent_key = self._k("spend", date, "agent", agent)
        global_key = self._k("spend", date, "global")
        model_key = self._k("spend", date, "model", model)
        tokens_key = self._k("tokens", date, "agent", agent)
        p = self.r.pipeline()
        p.incrbyfloat(agent_key, usd)
        p.incrbyfloat(global_key, usd)
        p.incrbyfloat(model_key, usd)
        for field, value in (usage or {}).items():
            if value:
                p.hincrby(tokens_key, field, int(value))
        for key in (agent_key, global_key, model_key, tokens_key):
            p.expire(key, DAY_TTL)
        results = p.execute()
        return float(results[0]), float(results[1])

    def count_request(self, agent, status):
        key = self._k("requests", utc_date(self.clock()), "agent", agent)
        p = self.r.pipeline()
        p.hincrby(key, "%dxx" % (int(status) // 100), 1)
        p.expire(key, DAY_TTL)
        p.execute()

    def mark_alert(self, agent, name):
        """Record that alert `name` fired today; True if it is new."""
        key = self._k("alerts", utc_date(self.clock()), "agent", agent)
        p = self.r.pipeline()
        p.sadd(key, str(name))
        p.expire(key, DAY_TTL)
        added, _ = p.execute()
        return bool(added)

    # ── agent authentication ───────────────────────────────────────────
    def set_agent_token(self, agent, token_sha256):
        self.r.set(self._k("auth", "agent", agent), token_sha256.lower())

    def agent_token(self, agent):
        return self.r.get(self._k("auth", "agent", agent))

    def delete_agent_token(self, agent):
        self.r.delete(self._k("auth", "agent", agent))

    # ── rate limit & circuit breaker ───────────────────────────────────
    def rate_hit(self, agent):
        minute = int(self.clock() // 60)
        key = self._k("rate", agent, minute)
        p = self.r.pipeline()
        p.incr(key)
        p.expire(key, 120)
        count, _ = p.execute()
        return int(count)

    def circuit_open_until(self, agent):
        value = self.r.get(self._k("cb", "open", agent))
        if value is None:
            return None
        until = float(value)
        return until if until > self.clock() else None

    def open_circuit(self, agent, cooldown):
        until = self.clock() + cooldown
        self.r.set(self._k("cb", "open", agent), repr(until), ex=max(1, int(cooldown) + 1))
        self.r.delete(self._k("cb", "failures", agent))
        return until

    def reset_circuit(self, agent):
        self.r.delete(self._k("cb", "open", agent), self._k("cb", "failures", agent))

    def record_failure(self, agent):
        key = self._k("cb", "failures", agent)
        p = self.r.pipeline()
        p.incr(key)
        p.expire(key, 3600)
        count, _ = p.execute()
        return int(count)

    def record_success(self, agent):
        self.r.delete(self._k("cb", "failures", agent))

    # ── events ─────────────────────────────────────────────────────────
    def publish(self, event):
        event = dict(event)
        event.setdefault("ts", self.clock())
        self.r.publish(EVENTS_CHANNEL, json.dumps(event))

    def subscribe(self):
        pubsub = self.r.pubsub(ignore_subscribe_messages=True)
        pubsub.subscribe(EVENTS_CHANNEL)
        return pubsub

    # ── reporting ──────────────────────────────────────────────────────
    def snapshot(self, date=None, default_limit=0.0):
        date = date or utc_date(self.clock())
        names = set()
        for kind in ("spend", "requests"):
            prefix = self._k(kind, date, "agent", "")
            names.update(key[len(prefix):] for key in self.r.scan_iter(match=prefix + "*"))
        agents = {}
        for agent in sorted(names):
            agents[agent] = {
                "usd": self.spend(agent, date),
                "limit_usd": self.limit(agent, default_limit),
                "tokens": {k: int(v) for k, v in self.r.hgetall(self._k("tokens", date, "agent", agent)).items()},
                "requests": {k: int(v) for k, v in self.r.hgetall(self._k("requests", date, "agent", agent)).items()},
            }
        models = {}
        mprefix = self._k("spend", date, "model", "")
        for key in self.r.scan_iter(match=mprefix + "*"):
            models[key[len(mprefix):]] = float(self.r.get(key) or 0.0)
        return {
            "date": date,
            "global_usd": self.global_spend(date),
            "agents": agents,
            "models": models,
        }

    def history(self, days=7):
        now = self.clock()
        return {utc_date(now - i * 86400): self.global_spend(utc_date(now - i * 86400)) for i in range(days)}

    # ── loop detection ─────────────────────────────────────────────────
    def loop_hit(self, agent, fingerprint, window):
        """Count consecutive requests with the same fingerprint.

        The run restarts when the fingerprint changes or `window` seconds
        have passed since its first request. Returns the run length.
        """
        key = self._k("loop", agent)
        now = self.clock()
        cur = self.r.hgetall(key)
        if cur.get("fp") == fingerprint and now - float(cur.get("start", 0)) <= window:
            count = int(self.r.hincrby(key, "count", 1))
        else:
            self.r.delete(key)
            self.r.hset(key, mapping={"fp": fingerprint, "count": 1, "start": repr(now)})
            count = 1
        self.r.expire(key, max(60, int(window) * 2))
        return count

    def loop_reset(self, agent):
        self.r.delete(self._k("loop", agent))

    # ── recording & replay ─────────────────────────────────────────────
    def set_record(self, agent, enabled):
        if enabled:
            self.r.set(self._k("record", agent), "1")
        else:
            self.r.delete(self._k("record", agent))

    def record_enabled(self, agent):
        return self.r.get(self._k("record", agent)) == "1"

    def set_replay(self, agent, recording, total):
        self.r.hset(self._k("replay", agent), mapping={"recording": recording, "pos": 0, "total": int(total)})

    def clear_replay(self, agent):
        self.r.delete(self._k("replay", agent))

    def replay_state(self, agent):
        state = self.r.hgetall(self._k("replay", agent))
        if not state:
            return None
        return {"recording": state["recording"], "pos": int(state["pos"]), "total": int(state["total"])}

    def replay_advance(self, agent):
        self.r.hincrby(self._k("replay", agent), "pos", 1)

    # ── message bus (Redis streams) ────────────────────────────────────
    def bus_publish(self, topic, fields, maxlen):
        return self.r.xadd(self._k("bus", topic), fields, maxlen=int(maxlen), approximate=False)

    def bus_last_id(self, topic):
        last = self.r.xrevrange(self._k("bus", topic), count=1)
        return last[0][0] if last else "0-0"

    def bus_read(self, topic, after, count, block_ms=0):
        """Entries after cursor `after`, blocking up to block_ms if none."""
        key = self._k("bus", topic)
        entries = self.r.xrange(key, min="(" + after, max="+", count=count)
        if not entries and block_ms > 0:
            res = self.r.xread({key: after}, count=count, block=int(block_ms))
            entries = res[0][1] if res else []
        return entries

    def bus_topics(self):
        prefix = self._k("bus", "")
        return sorted(key[len(prefix):] for key in self.r.scan_iter(match=prefix + "*"))
