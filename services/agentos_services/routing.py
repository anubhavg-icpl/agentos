"""Cost-aware model routing.

Applied to the `model` field of a request body before it is forwarded:

  1. static rewrites, per agent-id prefix (longest prefix wins) and then
     global;
  2. with strategy = "cheapest", the cheapest member (per pricing.json) of
     the equivalence group the model belongs to;
  3. budget-aware downgrade: once an agent has used threshold_pct of its
     daily budget, a model costlier than the configured cheaper model of the
     same provider is replaced by it.

A request is never routed to another vendor's model: the target's vendor
(the "provider" field in pricing.json) must equal the requested model's
vendor, or, when that is unknown, the gateway provider's name.
"""

import logging

log = logging.getLogger("agentos.routing")


class Router:
    def __init__(self, cfg, pricing):
        self.cfg = cfg or {}
        self.pricing = pricing

    # ── pricing helpers ────────────────────────────────────────────────
    def vendor(self, model):
        rates, priced = self.pricing.rates(model)
        return rates.get("provider") if priced else None

    def unit_cost(self, model):
        """Comparable cost of a model; None when it is not in pricing.json."""
        rates, priced = self.pricing.rates(model)
        if not priced:
            return None
        return float(rates.get("input_per_1m", 0.0)) + float(rates.get("output_per_1m", 0.0))

    def _allowed(self, source, target, provider):
        want = self.vendor(source)
        if want is None and provider in {m.get("provider") for m in self.pricing.models.values()}:
            want = provider
        have = self.vendor(target)
        return want is None or have is None or have == want

    # ── rules ──────────────────────────────────────────────────────────
    def _static(self, agent, model):
        best = None
        for prefix, table in (self.cfg.get("agents") or {}).items():
            if agent.startswith(prefix) and model in table and (best is None or len(prefix) > len(best[0])):
                best = (prefix, table[model])
        if best:
            return best[1], "rewrite:agent:" + best[0]
        table = self.cfg.get("rewrites") or {}
        if model in table:
            return table[model], "rewrite"
        return None, None

    def _cheapest(self, model, provider):
        for group in self.cfg.get("groups") or []:
            if model not in group:
                continue
            best, best_cost = model, self.unit_cost(model)
            if best_cost is None:
                return None, None
            for cand in group:
                cost = self.unit_cost(cand)
                if cost is not None and cost < best_cost and self._allowed(model, cand, provider):
                    best, best_cost = cand, cost
            if best != model:
                return best, "cheapest"
        return None, None

    def _downgrade(self, model, provider, used_pct):
        down = self.cfg.get("downgrade") or {}
        threshold = float(down.get("threshold_pct") or 0)
        target = (down.get("models") or {}).get(provider)
        if threshold <= 0 or not target or used_pct < threshold or target == model:
            return None, None
        cur, new = self.unit_cost(model), self.unit_cost(target)
        if cur is not None and new is not None and new >= cur:
            return None, None       # already cheaper: never upgrade
        return target, "downgrade:%g%%" % threshold

    def route(self, agent, provider, model, used_pct=0.0):
        """Return (routed_model, reason). reason is None when unchanged."""
        if not isinstance(model, str) or not model:
            return model, None
        current, reasons = model, []
        steps = [lambda m: self._static(agent, m)]
        if self.cfg.get("strategy") == "cheapest":
            steps.append(lambda m: self._cheapest(m, provider))
        steps.append(lambda m: self._downgrade(m, provider, used_pct))
        for step in steps:
            target, reason = step(current)
            if not target or target == current:
                continue
            if not self._allowed(current, target, provider):
                log.warning("refusing to route %s to %s: different vendor", current, target)
                continue
            current = target
            reasons.append(reason)
        return current, (",".join(reasons) or None)

    def describe(self, agent=None, provider=None, model=None, used_pct=0.0):
        out = {
            "strategy": self.cfg.get("strategy", "static"),
            "rewrites": self.cfg.get("rewrites") or {},
            "agents": self.cfg.get("agents") or {},
            "groups": self.cfg.get("groups") or [],
            "downgrade": self.cfg.get("downgrade") or {},
        }
        if agent and provider and model:
            routed, reason = self.route(agent, provider, model, used_pct)
            out["effective"] = {"agent": agent, "provider": provider, "model": model,
                                "routed_model": routed, "reason": reason, "used_pct": used_pct}
        return out
