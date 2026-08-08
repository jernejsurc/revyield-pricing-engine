#!/usr/bin/env python3
"""
RevYield - B2B Pricing Elasticity & Revenue Optimization Engine
data/seed_data.py

Generates a deterministic, economically coherent B2B SaaS dataset and loads it
into Neon PostgreSQL over SSL using psycopg v3 COPY.

The data is *simulated*, but it is not random noise. It is generated from an
explicit demand model defined in data/pricing_rules.json:

    Q_test = Q_control * (1 + E * %dP)      where E is the tier's elasticity

so the price test embedded in the data has a known ground truth, and
sql/01_price_elasticity.sql is graded on whether it recovers that truth.

Usage
-----
    # Inspect the generated economics without touching a database:
    python data/seed_data.py --dry-run --summary

    # Build the schema and load Neon in one shot:
    export DATABASE_URL='postgresql://user:pw@ep-xxx.eu-central-1.aws.neon.tech/revyield?sslmode=require'
    python data/seed_data.py --apply-schema --load --summary

    # Export flat files for Power BI / Google Sheets without a database:
    python data/seed_data.py --dry-run --csv-out ./exports
"""

from __future__ import annotations

import argparse
import calendar
import csv
import json
import os
import random
import sys
from dataclasses import dataclass, field
from datetime import date, timedelta
from pathlib import Path
from typing import Any, Iterable, Sequence

REPO_ROOT = Path(__file__).resolve().parent.parent
RULES_PATH = REPO_ROOT / "data" / "pricing_rules.json"
SCHEMA_PATH = REPO_ROOT / "data" / "schema.sql"

DEFAULT_ACCOUNTS = 1400
DEFAULT_SEED = 42


# =============================================================================
# Small date helpers (no pandas / numpy dependency - this must run anywhere)
# =============================================================================

def month_end(d: date) -> date:
    return date(d.year, d.month, calendar.monthrange(d.year, d.month)[1])


def add_months(d: date, n: int) -> date:
    total = (d.year * 12 + (d.month - 1)) + n
    year, month = divmod(total, 12)
    day = min(d.day, calendar.monthrange(year, month + 1)[1])
    return date(year, month + 1, day)


def months_between(start: date, end: date) -> int:
    return (end.year - start.year) * 12 + (end.month - start.month)


def month_starts(start: date, end: date) -> list[date]:
    out, cur = [], date(start.year, start.month, 1)
    last = date(end.year, end.month, 1)
    while cur <= last:
        out.append(cur)
        cur = add_months(cur, 1)
    return out


# =============================================================================
# Domain records
# =============================================================================

@dataclass
class Account:
    account_id: int
    company_name: str
    industry: str
    region: str
    employee_count: int
    signup_date: date
    initial_tier: str
    current_tier: str
    account_status: str = "active"
    churn_date: date | None = None
    variant: str = "control"
    base_seats: int = 1
    usage: dict[date, tuple[int, int, float]] = field(default_factory=dict)


@dataclass
class Deal:
    account_id: int
    deal_id: str
    contract_tier: str
    deal_type: str
    deal_stage: str
    pricing_variant: str
    contracted_seats: int
    list_price: float
    realized_price: float
    unit_cost: float
    win_probability: float
    contract_term_months: int
    contract_start_date: date | None
    contract_end_date: date | None
    close_date: date


# =============================================================================
# Generator
# =============================================================================

class RevYieldGenerator:
    """Deterministic generator for the whole RevYield dataset."""

    COMPANY_STEMS = [
        "Nord", "Helio", "Vertex", "Lumen", "Atlas", "Corvus", "Aurora", "Kestrel",
        "Basalt", "Cobalt", "Delphi", "Ember", "Fjord", "Granite", "Halcyon", "Ionic",
        "Juniper", "Kepler", "Larkspur", "Meridian", "Nimbus", "Onyx", "Pallas",
        "Quanta", "Ravel", "Solstice", "Tessera", "Umbra", "Veritas", "Wavelet",
        "Xenon", "Yarrow", "Zephyr", "Alloy", "Brindle", "Citrine", "Dovetail",
        "Estuary", "Foundry", "Gilder", "Harrow", "Inkwell", "Jetty", "Kiln",
    ]
    COMPANY_HEADS = [
        "Systems", "Analytics", "Labs", "Dynamics", "Logistics", "Technologies",
        "Networks", "Digital", "Works", "Group", "Industries", "Solutions",
        "Partners", "Ventures", "Data", "Cloud", "Robotics", "Interactive",
        "Holdings", "Collective", "Automation", "Signal",
    ]

    def __init__(self, rules: dict[str, Any], n_accounts: int, seed: int) -> None:
        self.rules = rules
        self.n_accounts = n_accounts
        self.rng = random.Random(seed)

        cal = rules["calendar"]
        self.window_start = date.fromisoformat(cal["data_window_start"])
        self.window_end = date.fromisoformat(cal["data_window_end"])

        exp = rules["experiment"]
        self.exp_start = date.fromisoformat(exp["window_start"])
        self.exp_end = date.fromisoformat(exp["window_end"])
        self.exp_eligible_types = set(exp["eligible_deal_types"])

        self.tiers = rules["tiers"]
        self.tier_order = sorted(self.tiers, key=lambda t: self.tiers[t]["rank"])
        self.capacity_threshold = rules["expansion_rules"]["capacity_threshold_pct"]
        self.sustained_months = rules["expansion_rules"]["sustained_months_required"]

        # Ground truth of the experiment: the expected realized price move per
        # tier, derived from the list uplift and the discount policy change.
        self.expected_price_delta = {
            tier: ((1 + cfg["test_list_uplift_pct"]) * (1 - cfg["discount"]["test_mean_pct"]))
            / (1 - cfg["discount"]["control_mean_pct"]) - 1
            for tier, cfg in self.tiers.items()
        }
        # Demand response implied by that price move: Q_test / Q_control.
        self.seat_multiplier = {
            tier: 1 + cfg["elasticity_coefficient"] * self.expected_price_delta[tier]
            for tier, cfg in self.tiers.items()
        }

        self.accounts: list[Account] = []
        self.deals: list[Deal] = []
        self._deal_counter = 0
        # Bresenham-style win allocator, keyed by (tier, arm). Coin-flipping the
        # expansion win/loss would inject binomial noise of the same order as the
        # elasticity signal itself, so wins are dealt out on an exact quota.
        self._win_credit: dict[tuple[str, str], float] = {}

    # -- utilities ------------------------------------------------------------

    def _stochastic_round(self, x: float) -> int:
        """Unbiased rounding. Plain round() would bias small seat counts upward
        and quietly corrupt the elasticity estimate on the Starter tier."""
        floor = int(x // 1)
        return floor + (1 if self.rng.random() < (x - floor) else 0)

    def _weighted_choice(self, options: Sequence[Any], weights: Sequence[float]) -> Any:
        return self.rng.choices(list(options), weights=list(weights), k=1)[0]

    def _next_deal_id(self, close: date) -> str:
        self._deal_counter += 1
        return f"HS-{close.year}-{self._deal_counter:06d}"

    # -- 1. accounts ----------------------------------------------------------

    def _draw_employee_count(self, tier: str) -> int:
        band = self.rules["segmentation"]["employee_bands"][tier]
        return int(min(band["max"], max(band["min"],
                   self.rng.lognormvariate(band["log_mu"], band["log_sigma"]))))

    def build_accounts(self) -> None:
        regions = self.rules["regions"]
        industries = self.rules["industries"]
        seg = self.rules["segmentation"]
        misclass = seg["misclassification_rate"]
        mix = seg["tier_mix"]

        # Signup months are growth-weighted: a healthy SaaS books more new logos
        # in recent months, which is also what puts real volume in the test window.
        months = month_starts(self.window_start, self.window_end)
        weights = [1.045 ** i for i in range(len(months))]

        names = [f"{s}{h}" for s in self.COMPANY_STEMS for h in self.COMPANY_HEADS]
        self.rng.shuffle(names)

        # --- Matched-pair randomisation ---------------------------------------
        # Simple 50/50 assignment leaves the arms unbalanced on the two variables
        # that dominate contracted volume - tier and deal size - and the resulting
        # noise is the same order of magnitude as the elasticity being measured.
        # Accounts are therefore assigned in twins that share tier, cohort month
        # and baseline seat count, with one twin sent to each arm. This is how a
        # credible commercial price test is actually run.
        tiers = [self._weighted_choice(list(mix), list(mix.values()))
                 for _ in range(self.n_accounts)]

        plan: list[tuple[str, str, date, int]] = []
        for tier in self.tier_order:
            n_tier = sum(1 for t in tiers if t == tier)
            for k in range((n_tier + 1) // 2):
                signup_month = self._weighted_choice(months, weights)
                base_seats = self._draw_seats(tier)
                plan.append((tier, "control", signup_month, base_seats))
                if 2 * k + 1 < n_tier:
                    plan.append((tier, "test", signup_month, base_seats))
        self.rng.shuffle(plan)          # so account_id order does not leak the pairing

        for i, (tier, arm, signup_month, base_seats) in enumerate(plan):
            region = self._weighted_choice(regions, [r["weight"] for r in regions])
            stem = names[i % len(names)]
            suffix = "" if i < len(names) else f" {i // len(names) + 1}"
            company = f"{stem}{suffix} {region['legal_suffix']}"

            # Headcount is drawn from the tier's band, except for a minority of
            # accounts placed in a neighbouring band: real sales teams do not tier
            # purely on firmographics, and that mismatch is genuine Phase 2 signal.
            headcount_tier = tier
            if self.rng.random() < misclass:
                idx = self.tier_order.index(tier)
                shift = self.rng.choice([-1, 1])
                headcount_tier = self.tier_order[min(len(self.tier_order) - 1, max(0, idx + shift))]

            self.accounts.append(Account(
                account_id=1000 + i,
                company_name=company,
                industry=self.rng.choice(industries),
                region=region["name"],
                employee_count=self._draw_employee_count(headcount_tier),
                signup_date=signup_month + timedelta(days=self.rng.randint(0, 27)),
                initial_tier=tier,
                current_tier=tier,
                variant=arm,
                base_seats=base_seats,
            ))

    # -- 2. usage -------------------------------------------------------------

    def build_usage(self) -> None:
        """Monthly utilisation trajectory per account.

        Seats are metered against the seat base the account actually bought, not
        against the tier's seat ceiling: the commercial signal an account manager
        acts on is "you are paying for 240 seats and using 310". API calls and
        storage are metered against the tier's included platform pools, which is
        what those entitlements genuinely are.

        Values above 1.0 mean the customer is over capacity - the expansion
        signal sql/02 hunts for."""
        for acct in self.accounts:
            ent = self.tiers[acct.initial_tier]["entitlements"]

            base = self.rng.triangular(0.22, 0.92, 0.52)
            drift = self.rng.gauss(0.021, 0.020)          # monthly utilisation growth
            seat_f = self.rng.gauss(1.0, 0.12)
            api_f = self.rng.gauss(1.0, 0.22)
            stor_f = self.rng.gauss(1.0, 0.18)

            for t, ms in enumerate(month_starts(acct.signup_date, self.window_end)):
                snapshot = month_end(ms)
                if snapshot > self.window_end:
                    break

                util = base * ((1 + drift) ** t) * self.rng.gauss(1.0, 0.055)
                # European B2B seasonality: August holidays, December shutdown.
                util *= {8: 0.92, 12: 0.88}.get(snapshot.month, 1.0)
                util = min(1.85, max(0.04, util))

                acct.usage[snapshot] = (
                    max(0, self._stochastic_round(acct.base_seats * util * max(0.2, seat_f))),
                    max(0, self._stochastic_round(ent["included_api_calls"] * util * max(0.2, api_f))),
                    round(max(0.0, ent["included_storage_gb"] * util * max(0.2, stor_f)), 2),
                )

    def _utilisation(self, acct: Account, snapshot: date) -> float:
        """Weighted utilisation score for one month, using the same weights the
        Expansion Readiness Index applies in sql/02."""
        row = acct.usage.get(snapshot)
        if row is None:
            return 0.0
        ent = self.tiers[acct.current_tier]["entitlements"]
        w = self.rules["expansion_rules"]["readiness_index_weights"]
        seats, api, storage = row
        return (
            w["seat_utilization"] * seats / acct.base_seats
            + w["api_utilization"] * api / ent["included_api_calls"]
            + w["storage_utilization"] * storage / ent["included_storage_gb"]
        )

    def _sustained_breach(self, acct: Account, upto: date) -> bool:
        checks = [add_months(upto, -i) for i in range(self.sustained_months)]
        vals = [self._utilisation(acct, month_end(c)) for c in checks]
        return all(v >= self.capacity_threshold for v in vals) and any(vals)

    # -- 3. deals -------------------------------------------------------------

    def build_deals(self) -> None:
        for acct in self.accounts:
            self._build_account_deals(acct)
        self._price_deals()
        self._truncate_usage_after_churn()

    def _build_account_deals(self, acct: Account) -> None:
        tier = acct.initial_tier
        cfg = self.tiers[tier]
        seats = acct.base_seats          # matched across the account's twin in the other arm

        contract_start = acct.signup_date
        deal_type = "new_business"

        while contract_start <= self.window_end:
            terms = cfg["contract_term_weights"]
            term = int(self._weighted_choice(list(terms), list(terms.values())))
            contract_end = add_months(contract_start, term)

            close = contract_start if deal_type == "new_business" else \
                contract_start - timedelta(days=self.rng.randint(1, 21))

            self._stage_deal(acct, tier, deal_type, "closed_won", seats, term,
                             contract_start, contract_end, close)

            # Mid-term expansions, sold co-terminus with the parent contract.
            seats += self._build_expansions(acct, tier, seats, contract_start, contract_end)

            if contract_end > self.window_end:
                break  # contract still running at the end of the data window

            # Renewal decision, taken at the contract boundary.
            util = self._utilisation(acct, month_end(add_months(contract_end, -1)))
            hazard = cfg["annual_churn_rate"] * min(2.6, max(0.30, 1.85 - 1.15 * util))
            churn_prob = 1 - (1 - min(0.95, hazard)) ** (term / 12)
            if self.rng.random() < churn_prob:
                acct.account_status = "churned"
                acct.churn_date = contract_end
                return

            # Sustained over-capacity pushes the account up a tier at renewal.
            if util >= 1.05 and tier != self.tier_order[-1] and self.rng.random() < 0.45:
                tier = self.tier_order[self.tier_order.index(tier) + 1]
                cfg = self.tiers[tier]
                acct.current_tier = tier
                seats = max(seats, self._draw_seats(tier))
                deal_type = "upgrade"
            else:
                deal_type = "renewal"

            contract_start = contract_end

        self._build_open_pipeline(acct, tier, seats)

    def _award_win(self, acct: Account, tier: str, close: date) -> bool:
        """Deal an expansion win from an exact quota rather than flipping a coin.

        Win rates are held identical across arms by design, so any difference the
        analysis finds in win rate is noise - and this allocator drives that noise
        to under one deal per cell, leaving contracted volume as the only channel
        the modelled elasticity flows through."""
        arm = acct.variant if (self.exp_start <= close <= self.exp_end
                               and "expansion" in self.exp_eligible_types) else "not_in_test"
        key = (tier, arm)
        credit = self._win_credit.get(key, 0.0) + self.tiers[tier]["expansion_win_rate_control"]
        if credit >= 1.0:
            self._win_credit[key] = credit - 1.0
            return True
        self._win_credit[key] = credit
        return False

    def _build_expansions(self, acct: Account, tier: str, seats: int,
                          start: date, end: date) -> int:
        """Return the incremental seats added mid-contract."""
        added = 0
        horizon = min(end, self.window_end)
        for ms in month_starts(add_months(start, 2), horizon):
            if added and self.rng.random() < 0.75:
                break                      # at most a couple of add-ons per term
            snapshot = month_end(ms)
            if snapshot > self.window_end or months_between(snapshot, end) < 2:
                continue
            if not self._sustained_breach(acct, snapshot):
                continue
            if self.rng.random() > 0.34:
                continue

            close = snapshot - timedelta(days=self.rng.randint(0, 20))
            if close < start:
                continue

            inc = max(1, self._stochastic_round(seats * self.rng.uniform(0.18, 0.45)))
            if self._award_win(acct, tier, close):
                co_term = max(1, months_between(close, end))
                self._stage_deal(acct, tier, "expansion", "closed_won", inc, co_term,
                                 close, end, close)
                added += inc
            else:
                self._stage_deal(acct, tier, "expansion", "closed_lost", inc, 12,
                                 None, None, close)
        return added

    def _build_open_pipeline(self, acct: Account, tier: str, seats: int) -> None:
        """Live opportunities closing after the data window - the raw material for
        the Weighted Pipeline Forecast measure in Power BI."""
        if acct.account_status == "churned" or self.rng.random() > 0.22:
            return
        close = self.window_end + timedelta(days=self.rng.randint(5, 95))
        inc = max(1, self._stochastic_round(seats * self.rng.uniform(0.15, 0.5)))
        prob = self._weighted_choice([0.20, 0.40, 0.60, 0.80], [0.30, 0.30, 0.25, 0.15])
        self._stage_deal(acct, tier, "expansion", "open", inc, 12, None, None, close,
                         win_probability=prob)

    def _draw_seats(self, tier: str) -> int:
        s = self.tiers[tier]["typical_seats"]
        return max(1, self._stochastic_round(
            self.rng.triangular(s["min"], s["max"], s["mode"])))

    def _stage_deal(self, acct: Account, tier: str, deal_type: str, stage: str,
                    seats: int, term: int, cstart: date | None, cend: date | None,
                    close: date, win_probability: float | None = None) -> None:
        """Record a deal with pricing deliberately left blank. Prices depend on the
        experiment arm, which is only applied once every deal exists."""
        if win_probability is None:
            win_probability = 1.0 if stage == "closed_won" else 0.0
        self.deals.append(Deal(
            account_id=acct.account_id,
            deal_id=self._next_deal_id(close),
            contract_tier=tier,
            deal_type=deal_type,
            deal_stage=stage,
            pricing_variant="not_in_test",
            contracted_seats=seats,
            list_price=0.0,
            realized_price=0.0,
            unit_cost=0.0,
            win_probability=win_probability,
            contract_term_months=term,
            contract_start_date=cstart,
            contract_end_date=cend,
            close_date=close,
        ))

    # -- 4. pricing: apply the experiment ------------------------------------

    def _price_deals(self) -> None:
        variant_by_account = {a.account_id: a.variant for a in self.accounts}

        for deal in self.deals:
            cfg = self.tiers[deal.contract_tier]
            in_window = self.exp_start <= deal.close_date <= self.exp_end
            eligible = deal.deal_type in self.exp_eligible_types

            if in_window and eligible:
                deal.pricing_variant = variant_by_account[deal.account_id]
            else:
                deal.pricing_variant = "not_in_test"

            is_test = deal.pricing_variant == "test"

            # Demand response. Applied to quantity only: win rates are held equal
            # across arms so the recovered elasticity is a clean seat elasticity
            # and not a blend of two different behavioural effects.
            if is_test:
                deal.contracted_seats = max(1, self._stochastic_round(
                    deal.contracted_seats * self.seat_multiplier[deal.contract_tier]))

            uplift = cfg["test_list_uplift_pct"] if is_test else 0.0
            disc_cfg = cfg["discount"]
            disc_mean = disc_cfg["test_mean_pct"] if is_test else disc_cfg["control_mean_pct"]
            discount = min(disc_cfg["max_pct"], max(0.0,
                           self.rng.gauss(disc_mean, disc_cfg["std_pct"])))

            list_per_seat = cfg["annual_list_price_per_seat"] * (1 + uplift)
            deal.list_price = round(deal.contracted_seats * list_per_seat, 2)
            deal.realized_price = round(deal.list_price * (1 - discount), 2)
            # Cost to serve does not move with the price card.
            deal.unit_cost = round(deal.contracted_seats * cfg["annual_cost_to_serve_per_seat"], 2)

    def _truncate_usage_after_churn(self) -> None:
        for acct in self.accounts:
            if acct.churn_date:
                acct.usage = {d: v for d, v in acct.usage.items() if d <= acct.churn_date}

    # -- orchestration --------------------------------------------------------

    def generate(self) -> None:
        self.build_accounts()
        self.build_usage()
        self.build_deals()

    # -- row projections for COPY / CSV --------------------------------------

    def account_rows(self) -> list[tuple]:
        return [(a.account_id, a.company_name, a.industry, a.region, a.employee_count,
                 a.signup_date, a.current_tier, a.account_status, a.churn_date)
                for a in self.accounts]

    def entitlement_rows(self) -> list[tuple]:
        rows = []
        for tier, cfg in self.tiers.items():
            ent = cfg["entitlements"]
            rows.append((
                tier, cfg["rank"], cfg["annual_list_price_per_seat"],
                cfg["annual_cost_to_serve_per_seat"], ent["included_seats"],
                ent["included_api_calls"], ent["included_storage_gb"],
                cfg["elasticity_coefficient"], cfg["test_list_uplift_pct"],
                self.capacity_threshold,
                round(1 - cfg["annual_cost_to_serve_per_seat"] / cfg["annual_list_price_per_seat"], 4),
            ))
        return sorted(rows, key=lambda r: r[1])

    def usage_rows(self) -> list[tuple]:
        return [(a.account_id, snap, seats, api, storage)
                for a in self.accounts
                for snap, (seats, api, storage) in sorted(a.usage.items())]

    def transaction_rows(self) -> list[tuple]:
        return [(d.account_id, d.deal_id, d.contract_tier, d.deal_type, d.deal_stage,
                 d.pricing_variant, d.contracted_seats, d.list_price, d.realized_price,
                 d.unit_cost, d.win_probability, d.contract_term_months,
                 d.contract_start_date, d.contract_end_date, d.close_date)
                for d in sorted(self.deals, key=lambda x: (x.close_date, x.account_id))]


# =============================================================================
# Validation summary - the numbers quoted in README.md come from here
# =============================================================================

def elasticity_by_tier(gen: RevYieldGenerator) -> dict[str, Any]:
    """Post-stratified read of the price test.

    New-business deals are several times larger than expansion add-ons, so a
    chance imbalance in deal mix between the two arms biases a naive tier-level
    average badly enough to flip the sign of the Starter elasticity. Each
    (tier, deal_type) stratum is therefore measured on its own and the strata are
    recombined using control-arm exposure as the weight - the same estimator
    sql/01_price_elasticity.sql implements in SQL.
    """
    exp = [d for d in gen.deals if d.pricing_variant in ("control", "test")]
    out: dict[str, Any] = {}
    port = {"control": 0.0, "test": 0.0, "w": 0.0}

    for tier in gen.tier_order:
        cell: dict[tuple[str, str], dict[str, float]] = {}
        for d in exp:
            if d.contract_tier != tier:
                continue
            c = cell.setdefault((d.deal_type, d.pricing_variant),
                                {"opps": 0, "wins": 0, "seats": 0, "rev": 0.0, "cost": 0.0})
            c["opps"] += 1
            if d.deal_stage == "closed_won":
                c["wins"] += 1
                c["seats"] += d.contracted_seats
                c["rev"] += d.realized_price
                c["cost"] += d.unit_cost

        strata = sorted({dt for dt, _ in cell}
                        & {dt for dt, arm in cell if arm == "test"})
        strata = [s for s in strata
                  if cell.get((s, "control"), {}).get("seats")
                  and cell.get((s, "test"), {}).get("seats")]

        w_opp = {s: cell[(s, "control")]["opps"] for s in strata}
        w_seat = {s: cell[(s, "control")]["seats"] for s in strata}
        tot_opp, tot_seat = sum(w_opp.values()), sum(w_seat.values())

        arms: dict[str, dict[str, float]] = {}
        for arm in ("control", "test"):
            q = sum(w_opp[s] * cell[(s, arm)]["seats"] / cell[(s, arm)]["opps"] for s in strata) / tot_opp
            pps = sum(w_seat[s] * cell[(s, arm)]["rev"] / cell[(s, arm)]["seats"] for s in strata) / tot_seat
            gm = sum(w_opp[s] * (cell[(s, arm)]["rev"] - cell[(s, arm)]["cost"]) / cell[(s, arm)]["opps"]
                     for s in strata) / tot_opp
            rev = sum(w_opp[s] * cell[(s, arm)]["rev"] / cell[(s, arm)]["opps"] for s in strata) / tot_opp
            wr = sum(w_opp[s] * cell[(s, arm)]["wins"] / cell[(s, arm)]["opps"] for s in strata) / tot_opp
            arms[arm] = {
                "opps": sum(cell[(s, arm)]["opps"] for s in strata),
                "seats": sum(cell[(s, arm)]["seats"] for s in strata),
                "q_per_opp": q,
                "price_per_seat": pps,
                "gm_per_opp": gm,
                "gm_pct": gm / rev if rev else 0.0,
                "win_rate": wr,
            }
            port[arm] += gm * tot_opp
        port["w"] += tot_opp

        dp = arms["test"]["price_per_seat"] / arms["control"]["price_per_seat"] - 1
        dq = arms["test"]["q_per_opp"] / arms["control"]["q_per_opp"] - 1
        out[tier] = {
            **arms,
            "strata": strata,
            "dp": dp,
            "dq": dq,
            "elasticity": dq / dp if dp else float("nan"),
            "gm_uplift": arms["test"]["gm_per_opp"] / arms["control"]["gm_per_opp"] - 1,
        }

    out["_portfolio"] = {
        "control": port["control"] / port["w"],
        "test": port["test"] / port["w"],
        "uplift": port["test"] / port["control"] - 1,
    }
    return out


def print_summary(gen: RevYieldGenerator) -> None:
    accounts, deals = gen.accounts, gen.deals
    won = [d for d in deals if d.deal_stage == "closed_won"]
    cur = "EUR"

    print("\n" + "=" * 78)
    print("REVYIELD - GENERATED DATASET SUMMARY")
    print("=" * 78)
    print(f"  Accounts                {len(accounts):>8,}   "
          f"(churned: {sum(1 for a in accounts if a.churn_date):,})")
    print(f"  Usage snapshots         {len(gen.usage_rows()):>8,}")
    print(f"  Transactions            {len(deals):>8,}   "
          f"(won {len(won):,} / lost {sum(1 for d in deals if d.deal_stage=='closed_lost'):,}"
          f" / open {sum(1 for d in deals if d.deal_stage=='open'):,})")
    print(f"  Data window             {gen.window_start} -> {gen.window_end}")
    print(f"  Experiment window       {gen.exp_start} -> {gen.exp_end}")

    # ---- A/B price test ----------------------------------------------------
    tiers = elasticity_by_tier(gen)

    print("\n" + "-" * 78)
    print("PRICE ELASTICITY TEST")
    print("  Q = contracted seats per opportunity, P = realized price per seat.")
    print("  Post-stratified on deal_type, combined with control-arm exposure weights.")
    print("-" * 78)
    print(f"{'Tier':<11}{'Arm':<9}{'Opps':>6}{'Seats':>9}{f'{cur}/seat':>10}"
          f"{'Win%':>7}{'%dP':>8}{'%dQ':>8}{'E':>7}{'GM%':>8}{'GM/opp':>10}{'dGM':>9}")

    for tier in gen.tier_order:
        m = tiers[tier]
        for arm in ("control", "test"):
            a = m[arm]
            tail = (f"{m['dp']:>8.1%}{m['dq']:>8.1%}{m['elasticity']:>7.2f}"
                    if arm == "test" else f"{'':>8}{'':>8}{'':>7}")
            uplift = f"{m['gm_uplift']:>+9.1%}" if arm == "test" else f"{'':>9}"
            print(f"{tier if arm == 'control' else '':<11}{arm:<9}{a['opps']:>6}"
                  f"{a['seats']:>9,}{a['price_per_seat']:>10,.2f}{a['win_rate']:>7.0%}"
                  f"{tail}{a['gm_pct']:>8.1%}{a['gm_per_opp']:>10,.0f}{uplift}")
        print(f"{'':<11}{'(design)':<9}{'':>6}{'':>9}{'':>10}{'':>7}"
              f"{gen.expected_price_delta[tier]:>8.1%}"
              f"{gen.seat_multiplier[tier] - 1:>8.1%}"
              f"{gen.tiers[tier]['elasticity_coefficient']:>7.2f}")

    p = tiers["_portfolio"]
    print(f"\n  Portfolio gross margin per opportunity: "
          f"{cur} {p['control']:,.0f} -> {cur} {p['test']:,.0f}  ({p['uplift']:+.1%})")

    # ---- Expansion readiness ----------------------------------------------
    ready = [a for a in accounts
             if a.account_status == "active" and a.usage
             and gen._sustained_breach(a, max(a.usage))]
    print("\n" + "-" * 78)
    print("EXPANSION READINESS")
    print("-" * 78)
    print(f"  Active accounts breaching {gen.capacity_threshold:.0%} capacity for "
          f"{gen.sustained_months} consecutive months: {len(ready):,} "
          f"({len(ready)/max(1,sum(1 for a in accounts if a.account_status=='active')):.1%} of active base)")

    # ---- Revenue / retention ----------------------------------------------
    print("\n" + "-" * 78)
    print("REVENUE BASE")
    print("-" * 78)
    for tier in gen.tier_order:
        tw = [d for d in won if d.contract_tier == tier]
        acv = sum(d.realized_price for d in tw)
        gm = sum(d.realized_price - d.unit_cost for d in tw)
        print(f"  {tier:<12} deals {len(tw):>5,}   booked ACV {cur} {acv:>13,.0f}   "
              f"blended GM {gm/acv if acv else 0:>6.1%}")

    live = [d for d in won
            if d.contract_start_date and d.contract_start_date <= gen.window_end < d.contract_end_date]
    pipeline = [d for d in deals if d.deal_stage == "open"]
    print(f"  {'Active MRR':<12} {cur} {sum(d.realized_price for d in live)/12:>26,.0f}"
          f"   ({len(live):,} live contracts)")
    print(f"  {'Weighted':<12} {cur} "
          f"{sum(d.realized_price * d.win_probability for d in pipeline):>26,.0f}"
          f"   ({len(pipeline):,} open deals)")
    print("=" * 78 + "\n")


# =============================================================================
# Persistence
# =============================================================================

CSV_SPECS = {
    "dim_accounts": ["account_id", "company_name", "industry", "region", "employee_count",
                     "signup_date", "current_tier", "account_status", "churn_date"],
    "dim_tier_entitlements": ["contract_tier", "tier_rank", "annual_list_price_per_seat",
                              "annual_cost_per_seat", "included_seats", "included_api_calls",
                              "included_storage_gb", "elasticity_coefficient",
                              "test_list_uplift_pct", "capacity_threshold_pct",
                              "target_gross_margin_pct"],
    "fact_usage_metrics": ["account_id", "recorded_date", "active_seats",
                           "api_calls_count", "storage_gb"],
    "fact_transactions": ["account_id", "deal_id", "contract_tier", "deal_type", "deal_stage",
                          "pricing_variant", "contracted_seats", "list_price", "realized_price",
                          "unit_cost", "win_probability", "contract_term_months",
                          "contract_start_date", "contract_end_date", "close_date"],
}


def table_payloads(gen: RevYieldGenerator) -> list[tuple[str, list[str], list[tuple]]]:
    return [
        ("dim_accounts", CSV_SPECS["dim_accounts"], gen.account_rows()),
        ("dim_tier_entitlements", CSV_SPECS["dim_tier_entitlements"], gen.entitlement_rows()),
        ("fact_usage_metrics", CSV_SPECS["fact_usage_metrics"], gen.usage_rows()),
        ("fact_transactions", CSV_SPECS["fact_transactions"], gen.transaction_rows()),
    ]


def write_csv(gen: RevYieldGenerator, out_dir: Path) -> None:
    out_dir.mkdir(parents=True, exist_ok=True)
    for table, cols, rows in table_payloads(gen):
        path = out_dir / f"{table}.csv"
        with path.open("w", newline="", encoding="utf-8") as fh:
            w = csv.writer(fh)
            w.writerow(cols)
            w.writerows(rows)
        print(f"  wrote {path}  ({len(rows):,} rows)")


def resolve_database_url(explicit: str | None) -> str:
    if explicit:
        return explicit
    if os.environ.get("DATABASE_URL"):
        return os.environ["DATABASE_URL"]

    env_file = REPO_ROOT / ".env"
    if env_file.exists():
        for line in env_file.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if line.startswith("DATABASE_URL="):
                return line.split("=", 1)[1].strip().strip("'\"")

    sys.exit(
        "ERROR: no database URL.\n"
        "  Set DATABASE_URL, pass --database-url, or add it to .env:\n"
        "    DATABASE_URL=postgresql://user:pw@ep-xxx.eu-central-1.aws.neon.tech/"
        "revyield?sslmode=require\n"
        "  (Neon requires sslmode=require.)\n"
        "  To inspect the data without a database: --dry-run --summary"
    )


def ensure_ssl(dsn: str) -> str:
    """Neon terminates non-SSL connections. Fail loudly rather than mysteriously."""
    if "sslmode=" in dsn:
        return dsn
    return dsn + ("&" if "?" in dsn else "?") + "sslmode=require"


def schema_sql_for_psycopg() -> str:
    """schema.sql carries its own BEGIN/COMMIT so it can be piped straight into
    psql. Inside psycopg's managed transaction those markers would commit the DDL
    early and split schema + data across two transactions, so they are stripped
    when the file is executed from Python."""
    return "\n".join(
        line for line in SCHEMA_PATH.read_text(encoding="utf-8").splitlines()
        if line.strip().upper() not in ("BEGIN;", "COMMIT;")
    )


def load_to_postgres(gen: RevYieldGenerator, dsn: str, apply_schema: bool) -> None:
    try:
        import psycopg
    except ImportError:
        sys.exit("ERROR: psycopg v3 is required.  pip install 'psycopg[binary]>=3.1'")

    dsn = ensure_ssl(dsn)
    with psycopg.connect(dsn, autocommit=False) as conn:
        with conn.cursor() as cur:
            if apply_schema:
                print(f"  applying {SCHEMA_PATH.relative_to(REPO_ROOT)} ...")
                cur.execute(schema_sql_for_psycopg())
            else:
                cur.execute("TRUNCATE fact_transactions, fact_usage_metrics, "
                            "dim_tier_entitlements, dim_accounts "
                            "RESTART IDENTITY CASCADE")

            for table, cols, rows in table_payloads(gen):
                stmt = f"COPY {table} ({', '.join(cols)}) FROM STDIN"
                with cur.copy(stmt) as cp:
                    for row in rows:
                        cp.write_row(row)
                print(f"  loaded {table:<24} {len(rows):>8,} rows")

            cur.execute("ANALYZE")
        conn.commit()
    print("  commit OK")


# =============================================================================
# CLI
# =============================================================================

def main(argv: Sequence[str] | None = None) -> int:
    p = argparse.ArgumentParser(
        description="Generate and load the RevYield pricing dataset.",
        formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--accounts", type=int, default=DEFAULT_ACCOUNTS,
                   help=f"number of accounts to generate (default {DEFAULT_ACCOUNTS})")
    p.add_argument("--seed", type=int, default=DEFAULT_SEED,
                   help=f"RNG seed; the dataset is fully deterministic (default {DEFAULT_SEED})")
    p.add_argument("--rules", type=Path, default=RULES_PATH,
                   help="path to pricing_rules.json")
    p.add_argument("--database-url", default=None,
                   help="Neon connection string; falls back to $DATABASE_URL then .env")
    p.add_argument("--apply-schema", action="store_true",
                   help="execute data/schema.sql before loading (drops and rebuilds tables)")
    p.add_argument("--load", action="store_true", help="load the dataset into PostgreSQL")
    p.add_argument("--dry-run", action="store_true",
                   help="generate only; never connect to a database")
    p.add_argument("--csv-out", type=Path, default=None,
                   help="also write the tables as CSV to this directory")
    p.add_argument("--summary", action="store_true",
                   help="print the validation summary (elasticity, margin, retention)")
    args = p.parse_args(argv)

    if args.dry_run and (args.load or args.apply_schema):
        p.error("--dry-run cannot be combined with --load / --apply-schema")
    if not (args.load or args.apply_schema or args.dry_run or args.csv_out):
        args.dry_run = args.summary = True   # sensible default: show me the data

    rules = json.loads(args.rules.read_text(encoding="utf-8"))

    print(f"RevYield seed  |  accounts={args.accounts}  seed={args.seed}  "
          f"rules={args.rules.name}")
    gen = RevYieldGenerator(rules, args.accounts, args.seed)
    gen.generate()

    if args.csv_out:
        write_csv(gen, args.csv_out)

    if args.load or args.apply_schema:
        load_to_postgres(gen, resolve_database_url(args.database_url), args.apply_schema)

    if args.summary:
        print_summary(gen)

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
