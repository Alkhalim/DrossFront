#include "steering_kernel_impl.h"
#include "flow_field_server_impl.h"

namespace {
    // Tunables — match spec §12.
    // SEPARATE_BUFFER is the slack added on top of the summed agent radii
    // before separation force kicks in. Two large agents (radius 2.4 each)
    // need ~4.8m to not overlap physically; with a 0.6m buffer separation
    // engages at 5.4m — comfortably wider than the bodies. Two small
    // agents (radius 1.0 each) get 2.6m — close to the previous constant
    // 2.5m so small-unit behavior is unchanged.
    constexpr float SEPARATE_BUFFER        = 0.6f;
    // Reduced from 6.0 — at peak (touching contact) the previous repel
    // produced a per-tick lateral kick large enough that the inertia
    // integrator could flip lateral velocity every tick when two units
    // ran roughly parallel (one tick they were on your right, next tick
    // on your left), driving a visible left-right wiggle within groups.
    // 3.0 keeps separation effective at preventing overlap but soft
    // enough that the integrator can't reverse lateral motion in one
    // tick at typical group speeds.
    constexpr float SEPARATE_REPEL         = 3.0f;
    // Hard cap on the per-tick separation contribution. Without this,
    // a unit caught between two others can accumulate sep up to
    // SEPARATE_REPEL × 2 (one push from each peer), and at peak that's
    // enough to overshoot the centerline and ricochet — same wiggle
    // pattern. Cap at half max_speed so separation can nudge a unit
    // sideways without ever reversing its forward motion.
    constexpr float SEPARATE_MAX_FRACTION  = 0.5f;
    // Reduce separation strength along the unit's direction of motion.
    // Without this, two units running the same direction with one
    // slightly ahead would push each other forward/backward — the rear
    // unit slowed by separation, the front sped up — and a flock would
    // spontaneously string into a single-file line over its travel.
    // 0.8 means full lateral (perpendicular-to-motion) separation and
    // 20% along-motion separation (just enough to prevent overlap when
    // a faster unit catches up to a slower one in front of it).
    constexpr float SEPARATE_PARALLEL_REDUCTION = 0.8f;
    constexpr float AVOID_DISTANCE         = 3.0f;     // unused in PF-A (no buildings list yet)
    constexpr float AVOID_REPEL            = 24.0f;
    // Cohesion as a fraction of the unit's own max_speed. A 5 m/s hound
    // gets 1.5 m/s pull, a 2 m/s crawler 0.6 m/s. Without per-unit scaling
    // a constant 2 m/s cohesion was 40% of a hound's speed but ~100% of a
    // crawler's, leaving slow chassis dragged everywhere by the centroid.
    constexpr float COHESION_FRACTION      = 0.3f;
    // Cohesion deadband — no pull when the unit is already within this
    // distance of the group centroid. Avoids the "always drifting toward
    // the middle" pile-up that made mixed-size groups bump constantly.
    // Within deadband, only SEPARATE acts — so units settle into their
    // natural body-radius spacing instead of stacking on the centroid.
    constexpr float COHESION_DEADBAND      = 4.0f;
    constexpr float COHESION_QUERY_RADIUS  = 16.0f;    // unused in PF-A (no group centroid yet)

    // Stuck detector — spec §7 + §12.
    //
    // Per-agent rolling displacement window. Each tick we record actual
    // displacement (pos - prev_pos), drop the oldest sample, and compute
    // mean(window) / (max_speed × delta). Below threshold for the whole
    // window means the agent isn't making progress toward whatever its
    // SEEK is asking for.
    //
    // 20 ticks at our 10 Hz physics is 2.0 s of memory — long enough to
    // ride out a momentary jam (peers shoving past each other on a
    // choke entrance), short enough that genuine wedging escalates
    // before the player notices a rooted unit.
    constexpr int   STUCK_WINDOW_TICKS                 = 20;
    // Below this fraction of expected per-tick distance, count the tick
    // as "no progress". 0.10 is generous enough that crawler chassis at
    // 2 m/s × 0.1 s = 0.2 m / tick still register as moving when they
    // make ≥0.02 m / tick — but a fully wedged unit (~0 m / tick) trips.
    constexpr float STUCK_PROGRESS_RATIO_THRESHOLD     = 0.10f;
    // Any single tick above this resets the escalation level. A flock
    // unit briefly stalled by a peer then ramming free shouldn't keep
    // a stale L1 cooldown that fires a second later.
    constexpr float STUCK_PROGRESS_RATIO_RESET         = 0.50f;
    // Level 1: perpendicular push-out duration. Spec calls 10 ticks.
    constexpr int   STUCK_LEVEL1_PUSHOUT_DURATION_TICKS = 10;
    // Cooldowns are wall-clock seconds (not ticks) so they're stable if
    // the physics rate ever changes again. 1.5 s after L1 fires before
    // we're allowed to fire L1 again or escalate to L2.
    constexpr float STUCK_LEVEL1_COOLDOWN_SEC          = 1.5f;
    constexpr float STUCK_LEVEL2_COOLDOWN_SEC          = 3.0f;  // terminal — L2 has no further escalation; the cooldown just gates re-firing if the unit re-acquires a target via set_agent_target
    // Multiplier applied to max_speed for the push-out vector magnitude.
    // 1.0 = "shove at full forward speed in the perpendicular direction".
    // We feed the result into the same desired-velocity composition path
    // so the inertia integrator still bounds the per-tick velocity change.
    constexpr float STUCK_PUSHOUT_STRENGTH             = 1.0f;
}

namespace drossfront {

namespace {
    // Returns the agent's progress ratio over its current window, or 1.0
    // if the window isn't full yet (don't false-positive newly-spawned
    // agents). Caller should only escalate when the window is full.
    float compute_progress_ratio(const AgentSoA &agents, int i, float delta) {
        if (agents.stuck_window_count[i] < STUCK_WINDOW_TICKS) {
            return 1.0f;
        }
        float expected_per_tick = agents.max_speed[i] * delta;
        if (expected_per_tick <= 0.0001f) {
            return 1.0f;  // immobile-by-design (e.g. zero max_speed) never triggers
        }
        float mean = agents.stuck_window_sum[i] / static_cast<float>(STUCK_WINDOW_TICKS);
        return mean / expected_per_tick;
    }
}

SteeringKernelImpl::SteeringKernelImpl() {}
SteeringKernelImpl::~SteeringKernelImpl() {}

void SteeringKernelImpl::set_flow_field_server(FlowFieldServerImpl *server) {
    server_ = server;
}

AgentHandle SteeringKernelImpl::register_agent(int /*unit_id*/, int agent_class, float radius,
                                                float max_speed, float max_accel, float max_turn_rate) {
    int idx = agents_.allocate_slot();
    agents_.agent_class[idx] = static_cast<uint8_t>(agent_class);
    agents_.radius[idx] = radius;
    agents_.max_speed[idx] = max_speed;
    agents_.max_accel[idx] = max_accel;
    agents_.max_turn_rate[idx] = max_turn_rate;
    agents_.flags[idx] = 0;
    agents_.field_id[idx] = INVALID_FIELD_ID;
    agents_.vel[idx] = {};
    return idx_to_handle(idx);
}

void SteeringKernelImpl::unregister_agent(AgentHandle handle) {
    int idx = handle_to_idx(handle);
    if (idx < 0 || idx >= agents_.count) return;
    agents_.free_slot(idx);
}

void SteeringKernelImpl::set_agent_pos(AgentHandle handle, godot::Vector3 world_pos) {
    int idx = handle_to_idx(handle);
    if (idx < 0 || idx >= agents_.count || !agents_.alive[idx]) return;
    agents_.pos[idx] = world_pos;
}

void SteeringKernelImpl::set_agent_target(AgentHandle handle, int group_id, FieldId field_id, int /*stance*/) {
    int idx = handle_to_idx(handle);
    if (idx < 0 || idx >= agents_.count || !agents_.alive[idx]) return;
    agents_.group_id[idx] = static_cast<uint32_t>(group_id);
    agents_.field_id[idx] = field_id;
    agents_.flags[idx] |= AGENT_FLAG_HAS_TARGET;
    // Any new target acquisition clears HALTED — a halted unit being given
    // a target should walk again. Avoids requiring every caller (goto_world,
    // GroupAura.setup, combat-driven re-issue) to remember to clear the flag.
    agents_.flags[idx] &= static_cast<uint8_t>(~AGENT_FLAG_HALTED);
    // PF-B-A6 fix: re-issuing a target also resets the stuck detector so
    // an agent that previously abandoned (stuck_level == 2) can escalate
    // again on the new attempt. Without this, the post-L2 agent is
    // permanently un-escalatable: L1's gate requires stuck_level == 0,
    // L2's requires stuck_level == 1, and the reset-on-progress block
    // requires actual movement which never happens for a still-wedged
    // unit. Clear the displacement window so the next ~20 ticks start
    // fresh measurements rather than carrying the prior stuck samples.
    agents_.stuck_level[idx] = 0;
    agents_.stuck_cooldown_remaining[idx] = 0.0f;
    agents_.stuck_window_count[idx] = 0;
    agents_.stuck_window_sum[idx] = 0.0f;
    agents_.stuck_window_head[idx] = 0;
    agents_.stuck_window[idx].fill(0.0f);
    agents_.stuck_pushout_frames_left[idx] = 0;
    agents_.flags[idx] &= static_cast<uint8_t>(~AGENT_FLAG_STUCK_PUSHOUT);
    // prev_pos NOT reset — the next displacement-record tick uses the
    // current pos vs. the last-known pos, which is correct for tracking
    // continuous motion.
}

void SteeringKernelImpl::set_agent_flag(AgentHandle handle, int flag, bool value) {
    int idx = handle_to_idx(handle);
    if (idx < 0 || idx >= agents_.count || !agents_.alive[idx]) return;
    if (value) agents_.flags[idx] |= static_cast<uint8_t>(flag);
    else       agents_.flags[idx] &= static_cast<uint8_t>(~flag);
}

godot::Vector3 SteeringKernelImpl::get_velocity(AgentHandle handle) {
    int idx = handle_to_idx(handle);
    if (idx < 0 || idx >= agents_.count || !agents_.alive[idx]) return {};
    return agents_.vel[idx];
}

AgentHandle SteeringKernelImpl::pop_path_unreachable_event(int *out_reason) {
    if (pending_failures_.empty()) {
        if (out_reason) *out_reason = 0;
        return 0;
    }
    // LIFO: most recent failure surfaces first. Order doesn't matter
    // since drain-all callers iterate until empty anyway.
    PathFailureEvent e = pending_failures_.back();
    pending_failures_.pop_back();
    if (out_reason) *out_reason = e.reason;
    return e.handle;
}

godot::Vector2i SteeringKernelImpl::pop_path_unreachable_event_v() {
    int r = 0;
    AgentHandle h = pop_path_unreachable_event(&r);
    return godot::Vector2i(static_cast<int>(h), r);
}

void SteeringKernelImpl::tick(float delta) {
    if (!server_) return;
    const int N = agents_.count;

    for (int i = 0; i < N; ++i) {
        if (!agents_.alive[i]) continue;

        // Stuck detector input — compute actual displacement since last
        // tick and slide it into the ring buffer. We do this before the
        // HAS_TARGET / HALTED short-circuits so the window has a clean
        // reference frame: displacement of 0 while halted is the truth,
        // and any subsequent re-target starts from the current pos.
        {
            godot::Vector3 dp = agents_.pos[i] - agents_.prev_pos[i];
            dp.y = 0.0f;
            float dist = dp.length();
            int head = agents_.stuck_window_head[i];
            float old = agents_.stuck_window[i][head];
            agents_.stuck_window[i][head] = dist;
            agents_.stuck_window_sum[i] += dist - old;
            agents_.stuck_window_head[i] = (head + 1) % STUCK_WINDOW_TICKS;
            if (agents_.stuck_window_count[i] < STUCK_WINDOW_TICKS) {
                agents_.stuck_window_count[i] += 1;
            }
            agents_.prev_pos[i] = agents_.pos[i];
        }

        // Stuck detector cooldown decrements unconditionally — it's a
        // wall-clock countdown.
        if (agents_.stuck_cooldown_remaining[i] > 0.0f) {
            agents_.stuck_cooldown_remaining[i] -= delta;
            if (agents_.stuck_cooldown_remaining[i] < 0.0f) {
                agents_.stuck_cooldown_remaining[i] = 0.0f;
            }
        }

        uint8_t f = agents_.flags[i];
        if (!(f & AGENT_FLAG_HAS_TARGET)) continue;
        if (f & (AGENT_FLAG_PARALYZED | AGENT_FLAG_HALTED)) {
            // Spec §6: halt zeroes velocity. Otherwise the orchestrator's
            // get_velocity() call would keep applying the agent's last
            // computed velocity via move_and_slide, drifting forever
            // until something else cleared the flag.
            agents_.vel[i] = {};
            continue;
        }

        godot::Vector3 pos = agents_.pos[i];
        float max_speed = agents_.max_speed[i];

        // SEEK from flow field (or aircraft direct seek; PF-A: ground only,
        // so we always sample). Aircraft branch lands in PF-B.
        godot::Vector2 flow = server_->sample(agents_.field_id[i], pos);
        godot::Vector3 seek(flow.x * max_speed, 0.0f, flow.y * max_speed);

        // Arrival (or unreachable goal): the field returns (0,0) flow at
        // the goal cell itself AND at any cell that's disconnected from
        // the goal. In both cases the agent should stop trying to drive
        // toward the goal — no SEEK, no COHESION pulling toward the
        // group centroid (which would cause stutter-step at the
        // destination). Keep SEPARATE so peers maintain spacing instead
        // of stacking on a single point. With seek=0 and coh=0, sep
        // decays to zero once peers are at SEPARATE_DISTANCE apart, and
        // inertia takes velocity to zero. Final state: units settle in
        // a small cluster around the goal, standing still.
        bool at_goal_or_unreachable = (flow.length_squared() < 0.0001f);
        if (at_goal_or_unreachable) {
            seek = godot::Vector3();
        }

        // SEPARATE pass — pairwise O(N^2). Acceptable at PF-A scale (one
        // squad type pilot, < 50 agents). PF-C swaps in SpatialIndex via a
        // GDScript-callable bridge.
        // Per-pair separation distance: summed agent radii + SEPARATE_BUFFER.
        // Without this, a constant SEPARATE_DISTANCE meant two large agents
        // (radius 2.4 each) only repelled within 2.5m even though their
        // physical bodies overlap until 4.8m+ apart — they constantly
        // bumped each other in mixed-size groups.
        const float my_radius = agents_.radius[i];
        // Forward direction for parallel-reduction. Use current velocity
        // when moving, fall back to the seek vector (flow direction) when
        // (near) stationary so combat-stopped units still benefit from
        // perpendicular-biased separation. has_forward gates the math —
        // if neither velocity nor seek give a meaningful direction we
        // apply unmodified separation.
        godot::Vector3 forward = agents_.vel[i];
        forward.y = 0.0f;
        float fwd_len = forward.length();
        bool has_forward = false;
        if (fwd_len > 0.1f) {
            forward = forward / fwd_len;
            has_forward = true;
        } else {
            float seek_len = seek.length();
            if (seek_len > 0.1f) {
                forward = seek / seek_len;
                has_forward = true;
            }
        }
        godot::Vector3 sep = {};
        for (int j = 0; j < N; ++j) {
            if (j == i || !agents_.alive[j]) continue;
            godot::Vector3 dp = pos - agents_.pos[j];
            dp.y = 0.0f;
            float d = dp.length();
            float min_dist = my_radius + agents_.radius[j] + SEPARATE_BUFFER;
            if (d <= 0.001f || d > min_dist) continue;
            float strength = SEPARATE_REPEL * (1.0f - d / min_dist);
            // Perpendicular-biased separation: scale strength down by
            // SEPARATE_PARALLEL_REDUCTION × |dot(dp_normalized, forward)|
            // so units lined up along their motion direction don't push
            // each other forward / backward (which would string a flock
            // into a single-file line).
            godot::Vector3 sep_dir = dp / d;  // normalized
            if (has_forward) {
                float parallel_factor = std::abs(sep_dir.x * forward.x + sep_dir.z * forward.z);
                float scale = 1.0f - parallel_factor * SEPARATE_PARALLEL_REDUCTION;
                strength *= scale;
            }
            sep += sep_dir * strength;
        }
        // Cap separation magnitude so a unit caught between two peers
        // (each contributing repel) can't accumulate enough force to
        // reverse its forward motion. See SEPARATE_MAX_FRACTION doc.
        float sep_len = sep.length();
        float sep_cap = max_speed * SEPARATE_MAX_FRACTION;
        if (sep_len > sep_cap) sep *= (sep_cap / sep_len);

        // COHESION — toward same-group centroid (computed on the fly here;
        // GroupAura caches it later when wired up via group_id lookup tables).
        // Skipped on arrival so it doesn't fight SEPARATE at the destination.
        // Two refinements over the original constant cap:
        //   - Deadband: no cohesion when within COHESION_DEADBAND of centroid.
        //     Prevents the "always pulling toward middle" pile-up that made
        //     mixed-size groups bump into each other constantly.
        //   - Fraction of own max_speed: a 5 m/s hound gets up to 1.5 m/s
        //     pull, a 2 m/s crawler 0.6 m/s. The previous absolute 2 m/s cap
        //     dragged slow chassis around at full speed.
        godot::Vector3 coh = {};
        if (!at_goal_or_unreachable) {
            godot::Vector3 centroid = {};
            int peers = 0;
            for (int j = 0; j < N; ++j) {
                if (j == i || !agents_.alive[j]) continue;
                if (agents_.group_id[j] != agents_.group_id[i]) continue;
                centroid += agents_.pos[j];
                ++peers;
            }
            if (peers > 0) {
                centroid /= static_cast<float>(peers);
                coh = centroid - pos;
                coh.y = 0.0f;
                float clen = coh.length();
                if (clen <= COHESION_DEADBAND) {
                    coh = godot::Vector3();
                } else {
                    // Push effective magnitude down by the deadband so the
                    // gradient is continuous at the boundary instead of
                    // stepping from 0 to full pull.
                    float effective = clen - COHESION_DEADBAND;
                    float cohesion_max = max_speed * COHESION_FRACTION;
                    if (effective > cohesion_max) effective = cohesion_max;
                    coh = (coh / clen) * effective;
                }
            }
        }

        // Stuck detector — escalation L1 (perpendicular push-out).
        // Skip when ENGAGED so combat-stopped units don't fire. Skip when
        // L1 is already burning, when escalation level is already past 0,
        // or when the cooldown timer hasn't elapsed.
        if (!(f & AGENT_FLAG_ENGAGED_IN_COMBAT) && !(f & AGENT_FLAG_STUCK_PUSHOUT)
                && agents_.stuck_level[i] == 0
                && agents_.stuck_cooldown_remaining[i] <= 0.0f
                && agents_.stuck_window_count[i] >= STUCK_WINDOW_TICKS) {
            float ratio = compute_progress_ratio(agents_, i, delta);
            if (ratio < STUCK_PROGRESS_RATIO_THRESHOLD) {
                // Perpendicular to forward, biased away from dominant sep
                // contribution. Forward already computed by the SEPARATE
                // pass above; sep too.
                godot::Vector3 push_dir;
                if (has_forward) {
                    // Right-perpendicular in XZ: (forward.z, 0, -forward.x).
                    godot::Vector3 perp(forward.z, 0.0f, -forward.x);
                    // sep already points away from peers (toward open
                    // space). Pick the perpendicular direction that aligns
                    // with sep's projection — that's the side away from
                    // the densest separation contribution.
                    float sep_dot_perp = sep.x * perp.x + sep.z * perp.z;
                    if (sep_dot_perp > 0.001f) {
                        push_dir = perp;     // sep has +perp component → +perp is open
                    } else {
                        push_dir = -perp;    // sep has 0 or -perp component → -perp is open (or arbitrary)
                    }
                } else {
                    // No forward direction available — push along sep's
                    // opposite (away from the crowd) or +X as last resort.
                    float sep_len_inner = sep.length();
                    if (sep_len_inner > 0.001f) {
                        push_dir = -sep / sep_len_inner;
                    } else {
                        push_dir = godot::Vector3(1.0f, 0.0f, 0.0f);
                    }
                }
                push_dir.y = 0.0f;
                float push_len = push_dir.length();
                if (push_len > 0.001f) push_dir /= push_len;

                agents_.stuck_pushout_dir[i] = push_dir;
                agents_.stuck_pushout_frames_left[i] = STUCK_LEVEL1_PUSHOUT_DURATION_TICKS;
                agents_.flags[i] |= AGENT_FLAG_STUCK_PUSHOUT;
                agents_.stuck_level[i] = 1;
                agents_.stuck_cooldown_remaining[i] = STUCK_LEVEL1_COOLDOWN_SEC;
                f = agents_.flags[i];  // refresh local copy so the next block sees STUCK_PUSHOUT
            }
        }

        // Stuck detector — escalation L2 (abandon).
        // Conditions: previously fired L1 (stuck_level == 1), the L1
        // cooldown has elapsed, push-out is no longer active, the window
        // is still showing no progress, not engaged.
        // Effect: zero velocity, set HALTED, clear HAS_TARGET, push a
        // PathFailureEvent for GDScript to drain. Set stuck_level = 2 +
        // L2 cooldown so we don't re-fire; the only way out is for
        // GDScript to call set_agent_target again (which clears HALTED
        // and HAS_TARGET re-asserts).
        if (!(f & AGENT_FLAG_ENGAGED_IN_COMBAT) && !(f & AGENT_FLAG_STUCK_PUSHOUT)
                && agents_.stuck_level[i] == 1
                && agents_.stuck_cooldown_remaining[i] <= 0.0f
                && agents_.stuck_window_count[i] >= STUCK_WINDOW_TICKS) {
            float ratio = compute_progress_ratio(agents_, i, delta);
            if (ratio < STUCK_PROGRESS_RATIO_THRESHOLD) {
                agents_.vel[i] = {};
                agents_.flags[i] |= AGENT_FLAG_HALTED;
                agents_.flags[i] &= static_cast<uint8_t>(~AGENT_FLAG_HAS_TARGET);
                agents_.stuck_level[i] = 2;
                agents_.stuck_cooldown_remaining[i] = STUCK_LEVEL2_COOLDOWN_SEC;
                pending_failures_.push_back({idx_to_handle(i), PATH_FAILURE_REPEATEDLY_STUCK});
                // Skip the rest of the tick body for this agent — vel
                // is already correct (zero) and we don't want SEEK to
                // overwrite it.
                continue;
            }
        }

        // While L1 push-out is active, replace SEEK with the push-out
        // vector at full strength. SEPARATE still acts so we don't push
        // into peers; COHESION still acts but is bounded so it can't
        // overwhelm the push.
        godot::Vector3 desired;
        if (f & AGENT_FLAG_STUCK_PUSHOUT) {
            godot::Vector3 push = agents_.stuck_pushout_dir[i] * (max_speed * STUCK_PUSHOUT_STRENGTH);
            desired = push + sep + coh;
            agents_.stuck_pushout_frames_left[i] -= 1;
            if (agents_.stuck_pushout_frames_left[i] <= 0) {
                agents_.flags[i] &= static_cast<uint8_t>(~AGENT_FLAG_STUCK_PUSHOUT);
                // Don't reset stuck_level here — that resets in the
                // progress-recovery branch below or in A6's L2 fire.
            }
        } else {
            desired = seek + sep + coh;
        }
        desired.y = 0.0f;
        float dlen = desired.length();
        if (dlen > max_speed) desired *= (max_speed / dlen);

        // Inertia: linear interpolation toward desired bounded by max_accel.
        godot::Vector3 v = agents_.vel[i];
        godot::Vector3 dv = desired - v;
        float dvlen = dv.length();
        float max_dv = agents_.max_accel[i] * delta;
        if (dvlen > max_dv) dv *= (max_dv / dvlen);
        v += dv;
        agents_.vel[i] = v;

        // Any tick of meaningful progress resets the escalation. Without
        // this, a unit that successfully push-outs and walks free would
        // still carry stuck_level = 1 and a cooldown that delays the next
        // L1 fire — so a *new* stuck event minutes later wouldn't escalate
        // properly. Resetting on success makes each stuck event independent.
        if (agents_.stuck_window_count[i] >= STUCK_WINDOW_TICKS) {
            float ratio_now = compute_progress_ratio(agents_, i, delta);
            if (ratio_now > STUCK_PROGRESS_RATIO_RESET) {
                agents_.stuck_level[i] = 0;
                agents_.stuck_cooldown_remaining[i] = 0.0f;
            }
        }
    }
}

#ifdef MOVEMENT_NATIVE_TESTS
float SteeringKernelImpl::test_get_progress_ratio(int idx, float delta) const {
    return compute_progress_ratio(agents_, idx, delta);
}
#endif

} // namespace drossfront
