#include "doctest.h"
#include "../src/steering_kernel_impl.h"
#include "../src/flow_field_server_impl.h"
#include "../src/types.h"
#include <godot_cpp/variant/vector3.hpp>
#include <vector>
#include <cmath>
#include <limits>
#include <algorithm>

using namespace drossfront;

TEST_CASE("stuck detector — displacement window populates and rolls") {
    // Build an open 32x32 grid at 2m cell, origin at (-32, -32).
    FlowFieldServerImpl s;
    s.configure_map(32, 32, 2.0f, -32.0f, -32.0f);
    s.set_agent_radius(0 /*SMALL*/, 0.5f);

    SteeringKernelImpl k;
    k.set_flow_field_server(&s);

    // Build a field so the agent has a valid HAS_TARGET pointer.
    FieldId fid = s.build_field(godot::Vector3(20, 0, 20), 0);
    REQUIRE(fid != INVALID_FIELD_ID);

    // Register one agent with max_speed = 5 m/s.
    AgentHandle h = k.register_agent(/*unit_id=*/1, /*agent_class=*/0,
                                     /*radius=*/0.5f, /*max_speed=*/5.0f,
                                     /*max_accel=*/20.0f, /*max_turn_rate=*/8.0f);
    REQUIRE(h != INVALID_AGENT_HANDLE);

    k.set_agent_target(h, /*group_id=*/1, fid, /*stance=*/0);

    // Set agent at origin and advance 20 ticks at 0.1 s with the agent
    // moving 0.5 m / tick (= max_speed * delta exactly). After the window
    // is full, progress_ratio should be ~1.0.
    godot::Vector3 p(0, 0, 0);
    for (int t = 0; t < 20; ++t) {
        k.set_agent_pos(h, p);
        k.tick(0.1f);
        p.x += 0.5f;
    }
    int idx = k.test_handle_to_idx(h);
    CHECK(k.test_get_progress_ratio(idx, 0.1f) == doctest::Approx(1.0f).epsilon(0.05));
}

TEST_CASE("stuck detector — stationary agent reports near-zero progress") {
    FlowFieldServerImpl s;
    s.configure_map(32, 32, 2.0f, -32.0f, -32.0f);
    s.set_agent_radius(0, 0.5f);
    SteeringKernelImpl k;
    k.set_flow_field_server(&s);
    FieldId fid = s.build_field(godot::Vector3(20, 0, 20), 0);
    REQUIRE(fid != INVALID_FIELD_ID);
    AgentHandle h = k.register_agent(1, 0, 0.5f, 5.0f, 20.0f, 8.0f);
    k.set_agent_target(h, 1, fid, 0);

    // Hold position for 20 ticks. progress_ratio should be ~0.
    for (int t = 0; t < 20; ++t) {
        k.set_agent_pos(h, godot::Vector3(0, 0, 0));
        k.tick(0.1f);
    }
    int idx = k.test_handle_to_idx(h);
    float ratio = k.test_get_progress_ratio(idx, 0.1f);
    CHECK(ratio < 0.05f);
    // Window count should have hit STUCK_WINDOW_TICKS.
    // (No accessor for this; if you find a clean way to expose it, add it,
    //  otherwise the indirect check via ratio < 1.0 is sufficient evidence
    //  the window is being populated.)
}

TEST_CASE("stuck detector — newly registered agent reports progress=1.0 (no false positives)") {
    FlowFieldServerImpl s;
    s.configure_map(32, 32, 2.0f, -32.0f, -32.0f);
    s.set_agent_radius(0, 0.5f);
    SteeringKernelImpl k;
    k.set_flow_field_server(&s);
    FieldId fid = s.build_field(godot::Vector3(20, 0, 20), 0);
    REQUIRE(fid != INVALID_FIELD_ID);
    AgentHandle h = k.register_agent(1, 0, 0.5f, 5.0f, 20.0f, 8.0f);
    k.set_agent_target(h, 1, fid, 0);

    // Tick a single time. Window not full yet.
    k.set_agent_pos(h, godot::Vector3(0, 0, 0));
    k.tick(0.1f);

    int idx = k.test_handle_to_idx(h);
    CHECK(k.test_get_progress_ratio(idx, 0.1f) == doctest::Approx(1.0f));
}

TEST_CASE("stuck detector — L1 fires after window of zero progress, push-out runs 10 ticks") {
    FlowFieldServerImpl s;
    s.configure_map(32, 32, 2.0f, -32.0f, -32.0f);
    s.set_agent_radius(0, 0.5f);
    SteeringKernelImpl k;
    k.set_flow_field_server(&s);
    FieldId fid = s.build_field(godot::Vector3(20, 0, 20), 0);
    REQUIRE(fid != INVALID_FIELD_ID);
    AgentHandle h = k.register_agent(1, 0, 0.5f, 5.0f, 20.0f, 8.0f);
    k.set_agent_target(h, 1, fid, 0);
    int idx = k.test_handle_to_idx(h);

    // Hold the agent at origin for 21 ticks — full window of zero
    // displacement, then one more tick for L1 to fire.
    for (int t = 0; t < 21; ++t) {
        k.set_agent_pos(h, godot::Vector3(0, 0, 0));
        k.tick(0.1f);
    }
    CHECK(k.test_get_stuck_level(idx) == 1);
    CHECK(k.test_get_pushout_frames(idx) > 0);

    // After STUCK_LEVEL1_PUSHOUT_DURATION_TICKS more ticks, push-out frame
    // counter has expired; STUCK_PUSHOUT flag clears. The agent's pos is
    // still externally pinned at origin so the window stays empty of
    // progress; stuck_level stays at 1 (cooldown gate prevents re-fire).
    for (int t = 0; t < 11; ++t) {
        k.set_agent_pos(h, godot::Vector3(0, 0, 0));
        k.tick(0.1f);
    }
    CHECK(k.test_get_pushout_frames(idx) <= 0);
}

TEST_CASE("stuck detector — meaningful progress resets stuck_level") {
    FlowFieldServerImpl s;
    s.configure_map(32, 32, 2.0f, -32.0f, -32.0f);
    s.set_agent_radius(0, 0.5f);
    SteeringKernelImpl k;
    k.set_flow_field_server(&s);
    FieldId fid = s.build_field(godot::Vector3(20, 0, 20), 0);
    REQUIRE(fid != INVALID_FIELD_ID);
    AgentHandle h = k.register_agent(1, 0, 0.5f, 5.0f, 20.0f, 8.0f);
    k.set_agent_target(h, 1, fid, 0);
    int idx = k.test_handle_to_idx(h);

    // 21 stationary ticks → L1 fires.
    for (int t = 0; t < 21; ++t) {
        k.set_agent_pos(h, godot::Vector3(0, 0, 0));
        k.tick(0.1f);
    }
    REQUIRE(k.test_get_stuck_level(idx) == 1);

    // Now feed 20 ticks of full-speed motion (0.5 m/tick at 10 Hz × 5 m/s).
    // Window refills with progress=1.0 samples, ratio_now > RESET (0.5),
    // stuck_level resets to 0.
    godot::Vector3 p(0, 0, 0);
    for (int t = 0; t < 20; ++t) {
        p.x += 0.5f;
        k.set_agent_pos(h, p);
        k.tick(0.1f);
    }
    CHECK(k.test_get_stuck_level(idx) == 0);
}

TEST_CASE("stuck detector — L1 push direction is away from peers, not into them") {
    // Setup: two agents. Agent A at origin, agent B at (0, 0, +1) — i.e.
    // B is in the +Z direction from A at distance 1m, inside the sep
    // threshold (r_A + r_B + SEPARATE_BUFFER = 1.6m). A's SEPARATE force
    // from B will point in -Z (away from B). A's `forward` is (1, 0, 0)
    // (goal at +X). Right-perpendicular to forward (1,0,0) is
    // `perp = (0, 0, -1)` (Godot left-handed XZ — perp.x =
    // forward.z = 0; perp.z = -forward.x = -1).
    //
    // sep ≈ (0, 0, -K) for some positive K → sep . perp = (-K)*(-1) = +K > 0.
    // So push_dir should be +perp = (0, 0, -1) — i.e., AWAY from peer B
    // (which is at +Z). If the bug returns, push_dir would be -perp = (0,0,+1)
    // — toward B.
    //
    // We can't directly read push_dir from the kernel (no test hook), but
    // we can verify behavior: hold A pinned at origin while B is held at
    // (0, 0, +1). Run enough ticks to fire L1, then UNPIN A for one tick
    // and observe the velocity sign on Z. Negative Z = away from B = correct.
    FlowFieldServerImpl s;
    s.configure_map(32, 32, 2.0f, -32.0f, -32.0f);
    s.set_agent_radius(0, 0.5f);
    SteeringKernelImpl k;
    k.set_flow_field_server(&s);
    FieldId fid = s.build_field(godot::Vector3(20, 0, 0), 0);  // goal at +X
    REQUIRE(fid != INVALID_FIELD_ID);

    AgentHandle a = k.register_agent(1, 0, 0.5f, 5.0f, 20.0f, 8.0f);
    AgentHandle b = k.register_agent(2, 0, 0.5f, 5.0f, 20.0f, 8.0f);
    k.set_agent_target(a, 1, fid, 0);
    k.set_agent_target(b, 1, fid, 0);
    int ai = k.test_handle_to_idx(a);

    // Pin both at chosen positions. A at origin, B at (0, 0, 1).
    // Distance = 1 m < sep threshold (r_A + r_B + SEPARATE_BUFFER = 1.6 m)
    // so separation force is active and sep accumulates in -Z each tick.
    // Many ticks of zero progress for A → L1 fires.
    for (int t = 0; t < 21; ++t) {
        k.set_agent_pos(a, godot::Vector3(0, 0, 0));
        k.set_agent_pos(b, godot::Vector3(0, 0, 1));
        k.tick(0.1f);
    }
    REQUIRE(k.test_get_stuck_level(ai) == 1);
    REQUIRE(k.test_get_pushout_frames(ai) > 0);

    // Now run one more tick. velocity for A should have negative Z
    // component (push away from B, which is at +Z).
    k.set_agent_pos(a, godot::Vector3(0, 0, 0));
    k.set_agent_pos(b, godot::Vector3(0, 0, 1));
    k.tick(0.1f);
    godot::Vector3 va = k.get_velocity(a);
    CHECK(va.z < 0.0f);  // CRITICAL: must be negative; positive means push toward peer (the bug)
}

TEST_CASE("stuck detector — L2 abandon zeroes velocity, sets HALTED, clears HAS_TARGET, pushes event") {
    FlowFieldServerImpl s;
    s.configure_map(32, 32, 2.0f, -32.0f, -32.0f);
    s.set_agent_radius(0, 0.5f);
    SteeringKernelImpl k;
    k.set_flow_field_server(&s);
    FieldId fid = s.build_field(godot::Vector3(20, 0, 20), 0);
    REQUIRE(fid != INVALID_FIELD_ID);
    AgentHandle h = k.register_agent(1, 0, 0.5f, 5.0f, 20.0f, 8.0f);
    k.set_agent_target(h, 1, fid, 0);
    int idx = k.test_handle_to_idx(h);

    // Sequence:
    //   Ticks 0-19 (20 ticks): fill window with zero displacement.
    //   Tick 20: window full + ratio<threshold → L1 fires; stuck_level=1,
    //            cooldown=1.5s, STUCK_PUSHOUT set, pushout_frames=10.
    //   Ticks 21-30: STUCK_PUSHOUT active for 10 ticks (pushout_frames
    //                decrements each). After tick 30, flag clears.
    //   During those 10 ticks, cooldown decrements from 1.5s by 0.1s/tick
    //   = 1.0s remaining after pushout ends.
    //   Need 10 more ticks (1.0s / 0.1s) for cooldown to reach 0.
    //   So tick 41 = first tick where stuck_level==1, cooldown<=0,
    //                STUCK_PUSHOUT off, window full, ratio<threshold.
    //   L2 fires, stuck_level=2, HALTED set, HAS_TARGET cleared, event
    //   pushed.
    // Total: ≈42 ticks. Run 50 to leave margin.
    for (int t = 0; t < 50; ++t) {
        k.set_agent_pos(h, godot::Vector3(0, 0, 0));
        k.tick(0.1f);
    }
    CHECK(k.test_get_stuck_level(idx) == 2);
    CHECK(k.test_pending_failure_count() == 1);

    // Drain the event.
    int reason = 0;
    AgentHandle popped = k.pop_path_unreachable_event(&reason);
    CHECK(popped == h);
    CHECK(reason == SteeringKernelImpl::PATH_FAILURE_REPEATEDLY_STUCK);

    // Subsequent pop returns 0/0.
    AgentHandle empty_pop = k.pop_path_unreachable_event(&reason);
    CHECK(empty_pop == 0);
    CHECK(reason == 0);
}

TEST_CASE("stuck detector — set_agent_target after L2 re-arms the detector for fresh escalation") {
    FlowFieldServerImpl s;
    s.configure_map(32, 32, 2.0f, -32.0f, -32.0f);
    s.set_agent_radius(0, 0.5f);
    SteeringKernelImpl k;
    k.set_flow_field_server(&s);
    FieldId fid = s.build_field(godot::Vector3(20, 0, 20), 0);
    REQUIRE(fid != INVALID_FIELD_ID);
    AgentHandle h = k.register_agent(1, 0, 0.5f, 5.0f, 20.0f, 8.0f);
    k.set_agent_target(h, 1, fid, 0);
    int idx = k.test_handle_to_idx(h);

    // 50 stationary ticks → L2 fires.
    for (int t = 0; t < 50; ++t) {
        k.set_agent_pos(h, godot::Vector3(0, 0, 0));
        k.tick(0.1f);
    }
    REQUIRE(k.test_get_stuck_level(idx) == 2);

    // Drain the event.
    int reason = 0;
    k.pop_path_unreachable_event(&reason);

    // Re-issue target. Detector state should reset.
    k.set_agent_target(h, 1, fid, 0);
    CHECK(k.test_get_stuck_level(idx) == 0);
    CHECK(k.test_get_pushout_frames(idx) == 0);

    // Now run 50 more stationary ticks — L1 + L2 should fire again on
    // this fresh round, proving the detector is genuinely re-armed.
    for (int t = 0; t < 50; ++t) {
        k.set_agent_pos(h, godot::Vector3(0, 0, 0));
        k.tick(0.1f);
    }
    CHECK(k.test_get_stuck_level(idx) == 2);
    CHECK(k.test_pending_failure_count() == 1);  // exactly one new event
}

TEST_CASE("aircraft branch — direct 3D seek toward target_pos, no flow-field sample") {
    FlowFieldServerImpl s;
    s.configure_map(32, 32, 2.0f, -32.0f, -32.0f);
    s.set_agent_radius(0, 0.5f);
    SteeringKernelImpl k;
    k.set_flow_field_server(&s);

    AgentHandle h = k.register_agent(1, 0, 0.5f, 10.0f, 40.0f, 8.0f);
    k.set_agent_flag(h, AGENT_FLAG_IS_AIRCRAFT, true);
    k.set_agent_pos(h, godot::Vector3(0, 0, 0));
    k.set_agent_target_pos(h, godot::Vector3(10, 5, 0));  // diagonal up + east
    k.tick(0.1f);
    godot::Vector3 v = k.get_velocity(h);
    CHECK(v.x > 0.0f);   // moving east
    CHECK(v.y > 0.0f);   // aircraft moves up — ground would have y == 0
    CHECK(std::abs(v.z) < 0.001f);  // no Z motion
}

TEST_CASE("aircraft branch — within 1m of target, seek is zero (hover)") {
    FlowFieldServerImpl s;
    s.configure_map(32, 32, 2.0f, -32.0f, -32.0f);
    s.set_agent_radius(0, 0.5f);
    SteeringKernelImpl k;
    k.set_flow_field_server(&s);

    AgentHandle h = k.register_agent(1, 0, 0.5f, 10.0f, 40.0f, 8.0f);
    k.set_agent_flag(h, AGENT_FLAG_IS_AIRCRAFT, true);
    k.set_agent_pos(h, godot::Vector3(0.5f, 0, 0));  // 0.5m from origin target
    k.set_agent_target_pos(h, godot::Vector3(0, 0, 0));
    k.tick(0.1f);
    godot::Vector3 v = k.get_velocity(h);
    // Velocity should be near zero — at_goal, no SEEK, no neighbors, no
    // cohesion (single agent). Only the inertia integrator might leave a
    // tiny residual but it should decay quickly.
    CHECK(v.length() < 1.0f);  // generous bound
}

TEST_CASE("aircraft branch — vertical motion counts as displacement progress") {
    FlowFieldServerImpl s;
    s.configure_map(32, 32, 2.0f, -32.0f, -32.0f);
    s.set_agent_radius(0, 0.5f);
    SteeringKernelImpl k;
    k.set_flow_field_server(&s);

    AgentHandle h = k.register_agent(1, 0, 0.5f, 10.0f, 40.0f, 8.0f);
    k.set_agent_flag(h, AGENT_FLAG_IS_AIRCRAFT, true);
    k.set_agent_target_pos(h, godot::Vector3(0, 10, 0));  // straight up
    int idx = k.test_handle_to_idx(h);

    // Manually advance the agent's pos +1m in Y per tick. Ground would
    // see this as zero displacement (Y projected away); aircraft sees the
    // full Y delta.
    godot::Vector3 p(0, 0, 0);
    for (int t = 0; t < 20; ++t) {
        k.set_agent_pos(h, p);
        k.tick(0.1f);
        p.y += 1.0f;  // exactly max_speed × delta (10 × 0.1) when full-throttle vertical
    }
    // progress_ratio should be ~1.0 — aircraft moving at max_speed
    // vertically registers as full progress, NOT zero.
    CHECK(k.test_get_progress_ratio(idx, 0.1f) == doctest::Approx(1.0f).epsilon(0.1));
    CHECK(k.test_get_stuck_level(idx) == 0);  // no escalation
}

// ─────────────────────────────────────────────────────────────────────────────
// Behavioral simulation tests — emergent multi-agent regression net.
// Each test constructs kernel + server from scratch (no shared state).
// Velocity is integrated into agent pos after each tick, mirroring the
// orchestrator's move_and_slide loop. Tests run in pure C++; no Godot
// runtime required.
// ─────────────────────────────────────────────────────────────────────────────

TEST_CASE("behavioral — flock traveling in same direction does not exhibit lateral wiggle") {
    FlowFieldServerImpl s;
    s.configure_map(64, 64, 2.0f, -64.0f, -64.0f);
    s.set_agent_radius(0, 0.5f);
    SteeringKernelImpl k;
    k.set_flow_field_server(&s);
    FieldId fid = s.build_field(godot::Vector3(50, 0, 0), 0);
    REQUIRE(fid != INVALID_FIELD_ID);

    // Spawn 5 agents in a tight row along Z, all heading toward +X.
    // group_id = 1 so cohesion applies — matches "one selection of 5 squads".
    std::vector<AgentHandle> handles;
    for (int z_off = -2; z_off <= 2; ++z_off) {
        AgentHandle h = k.register_agent(z_off + 100, 0, 0.5f, 5.0f, 20.0f, 8.0f);
        REQUIRE(h != INVALID_AGENT_HANDLE);
        k.set_agent_target(h, 1, fid, 0);
        k.set_agent_pos(h, godot::Vector3(-30.0f, 0.0f, static_cast<float>(z_off)));
        handles.push_back(h);
    }

    // Tick 200 frames (~20 s at 10 Hz). Mirror the orchestrator:
    // get_velocity AFTER tick, then advance pos by velocity × delta.
    constexpr float DELTA = 0.1f;
    constexpr int TICKS = 200;
    // Skip the first 30 ticks (acceleration ramp) and the last 40
    // (potential arrival deceleration). Measure lateral RMS during
    // steady-state travel: frames [30, 160).
    float lateral_velocity_sum_sq = 0.0f;
    int sample_count = 0;
    for (int t = 0; t < TICKS; ++t) {
        k.tick(DELTA);
        for (AgentHandle h : handles) {
            godot::Vector3 v = k.get_velocity(h);
            int idx = k.test_handle_to_idx(h);
            godot::Vector3 cur_pos = k.test_get_pos(idx);
            k.set_agent_pos(h, cur_pos + v * DELTA);
            if (t >= 30 && t < 160) {
                // Z component is the lateral axis when traveling in +X.
                lateral_velocity_sum_sq += v.z * v.z;
                sample_count += 1;
            }
        }
    }
    float lateral_rms = std::sqrt(lateral_velocity_sum_sq / std::max(sample_count, 1));
    INFO("Lateral velocity RMS during steady-state travel: " << lateral_rms << " m/s");
    // Threshold: agents traveling at ~5 m/s should have lateral velocity
    // well below 1 m/s on average. 0.8 m/s allows for normal inter-agent
    // separation nudges while flagging genuine persistent wiggle.
    // At HEAD (PARALLEL_REDUCTION=0.6) measured ~0.09 m/s — so 0.8 is
    // generous headroom; tighten to ~0.3 once behavior is fully verified.
    CHECK(lateral_rms < 0.8f);
}

TEST_CASE("behavioral — 5 squads converging on a single target spread out laterally") {
    FlowFieldServerImpl s;
    s.configure_map(64, 64, 2.0f, -64.0f, -64.0f);
    s.set_agent_radius(0, 0.5f);
    SteeringKernelImpl k;
    k.set_flow_field_server(&s);
    godot::Vector3 goal(30, 0, 0);
    FieldId fid = s.build_field(goal, 0);
    REQUIRE(fid != INVALID_FIELD_ID);

    // Spawn 5 agents in a starting cluster at (-30, 0, *) with 2 m Z gaps.
    std::vector<AgentHandle> handles;
    for (int z_off = -2; z_off <= 2; ++z_off) {
        AgentHandle h = k.register_agent(z_off + 200, 0, 0.5f, 5.0f, 20.0f, 8.0f);
        k.set_agent_target(h, 1, fid, 0);
        k.set_agent_pos(h, godot::Vector3(-30.0f, 0.0f, static_cast<float>(z_off) * 2.0f));
        handles.push_back(h);
    }

    // 400 ticks = 40 s — long enough to reach and settle near the goal.
    constexpr float DELTA = 0.1f;
    constexpr int TICKS = 400;
    for (int t = 0; t < TICKS; ++t) {
        k.tick(DELTA);
        for (AgentHandle h : handles) {
            int idx = k.test_handle_to_idx(h);
            godot::Vector3 cur_pos = k.test_get_pos(idx);
            godot::Vector3 v = k.get_velocity(h);
            k.set_agent_pos(h, cur_pos + v * DELTA);
        }
    }

    // Measure the spread along Z for agents that reached the goal area.
    float z_min = std::numeric_limits<float>::infinity();
    float z_max = -std::numeric_limits<float>::infinity();
    int near_goal_count = 0;
    for (AgentHandle h : handles) {
        int idx = k.test_handle_to_idx(h);
        godot::Vector3 p = k.test_get_pos(idx);
        // 15 m is a generous arrival radius — checks reachability, not
        // tight arrival. Full arrival radius from set_agent_target semantics
        // is typically ~2 m; 15 m here because clumped agents may park
        // slightly away from the exact goal cell.
        if ((p - goal).length() < 15.0f) {
            z_min = std::min(z_min, p.z);
            z_max = std::max(z_max, p.z);
            near_goal_count += 1;
        }
    }
    INFO("Agents near goal: " << near_goal_count << " / 5, Z spread: " << (z_max - z_min) << " m");
    // At least 4 of 5 should reach the goal area (one may be slow on the edges).
    CHECK(near_goal_count >= 4);
    // Z spread >= 3 m: agents are not stacking perfectly on top of each
    // other. This is a LENIENT bar — proper attack-spread would produce
    // 8–10 m. Currently PARALLEL_REDUCTION=0.6 still clumps somewhat;
    // attack-spread feature will raise this threshold.
    CHECK((z_max - z_min) >= 3.0f);
}

TEST_CASE("behavioral — agents spawned within mutual separation distance still make progress") {
    FlowFieldServerImpl s;
    s.configure_map(64, 64, 2.0f, -64.0f, -64.0f);
    s.set_agent_radius(0, 0.5f);
    SteeringKernelImpl k;
    k.set_flow_field_server(&s);
    FieldId fid = s.build_field(godot::Vector3(30, 0, 0), 0);
    REQUIRE(fid != INVALID_FIELD_ID);

    // Spawn 5 agents at tight 0.8 m gaps — well inside the SEPARATE
    // threshold (sum of radii 1.0 m + SEPARATE_BUFFER 0.6 m = 1.6 m).
    // Forces partially cancel but flow-field SEEK should drive net forward
    // motion. Verifies "initial jam" doesn't halt the group.
    std::vector<AgentHandle> handles;
    for (int z_off = -2; z_off <= 2; ++z_off) {
        AgentHandle h = k.register_agent(z_off + 300, 0, 0.5f, 5.0f, 20.0f, 8.0f);
        k.set_agent_target(h, 1, fid, 0);
        k.set_agent_pos(h, godot::Vector3(-30.0f, 0.0f, static_cast<float>(z_off) * 0.8f));
        handles.push_back(h);
    }

    // Record initial centroid X before any ticks.
    float initial_centroid_x = 0.0f;
    for (AgentHandle h : handles) {
        initial_centroid_x += k.test_get_pos(k.test_handle_to_idx(h)).x;
    }
    initial_centroid_x /= 5.0f;

    constexpr float DELTA = 0.1f;
    constexpr int TICKS = 100;  // 10 s — plenty for forward motion to develop
    for (int t = 0; t < TICKS; ++t) {
        k.tick(DELTA);
        for (AgentHandle h : handles) {
            int idx = k.test_handle_to_idx(h);
            godot::Vector3 cur_pos = k.test_get_pos(idx);
            godot::Vector3 v = k.get_velocity(h);
            k.set_agent_pos(h, cur_pos + v * DELTA);
        }
    }

    // No agent should have HALTED (stuck_level == 2). If the initial jam
    // overwhelms the seek, a unit may wedge and escalate to L2.
    for (AgentHandle h : handles) {
        int idx = k.test_handle_to_idx(h);
        CHECK(k.test_get_stuck_level(idx) < 2);
    }

    // Centroid should have moved at least 5 m forward in 10 s.
    // At 5 m/s max speed with partial separation drag, even 1 m/s net
    // forward motion covers 10 m — 5 m is a conservative lower bound.
    float final_centroid_x = 0.0f;
    for (AgentHandle h : handles) {
        final_centroid_x += k.test_get_pos(k.test_handle_to_idx(h)).x;
    }
    final_centroid_x /= 5.0f;
    float displacement = final_centroid_x - initial_centroid_x;
    INFO("Centroid displacement after 100 ticks: " << displacement << " m");
    CHECK(displacement >= 5.0f);
}

TEST_CASE("behavioral — two aircraft flying to nearby goals maintain separation") {
    FlowFieldServerImpl s;
    s.configure_map(64, 64, 2.0f, -64.0f, -64.0f);
    s.set_agent_radius(0, 0.5f);
    SteeringKernelImpl k;
    k.set_flow_field_server(&s);

    // Two aircraft at altitude 10, side-by-side at z = ±2, same goal.
    // Aircraft branch (B2) uses direct 3D seek toward target_pos.
    AgentHandle a = k.register_agent(401, 0, 0.5f, 10.0f, 40.0f, 8.0f);
    AgentHandle b = k.register_agent(402, 0, 0.5f, 10.0f, 40.0f, 8.0f);
    // Set IS_AIRCRAFT flag before set_agent_target_pos so the tick branch
    // picks up the flag on the very first tick.
    k.set_agent_flag(a, AGENT_FLAG_IS_AIRCRAFT, true);
    k.set_agent_flag(b, AGENT_FLAG_IS_AIRCRAFT, true);
    k.set_agent_pos(a, godot::Vector3(-20, 10, -2));
    k.set_agent_pos(b, godot::Vector3(-20, 10,  2));
    k.set_agent_target_pos(a, godot::Vector3(20, 10, 0));
    k.set_agent_target_pos(b, godot::Vector3(20, 10, 0));
    // Both are in default group_id=0 — cohesion + separation both apply
    // across the two agents since they share a group.

    constexpr float DELTA = 0.1f;
    constexpr int TICKS = 80;
    float min_distance = std::numeric_limits<float>::infinity();
    for (int t = 0; t < TICKS; ++t) {
        k.tick(DELTA);
        int idx_a = k.test_handle_to_idx(a);
        int idx_b = k.test_handle_to_idx(b);
        godot::Vector3 pa = k.test_get_pos(idx_a);
        godot::Vector3 pb = k.test_get_pos(idx_b);
        // Integrate positions.
        k.set_agent_pos(a, pa + k.get_velocity(a) * DELTA);
        k.set_agent_pos(b, pb + k.get_velocity(b) * DELTA);
        // Measure pairwise distance after integration (at updated positions).
        float d = (k.test_get_pos(idx_a) - k.test_get_pos(idx_b)).length();
        min_distance = std::min(min_distance, d);
    }
    INFO("Closest pairwise distance over 80 ticks: " << min_distance << " m");
    // Aircraft radius 0.5 m each; separation starts at r_a + r_b +
    // SEPARATE_BUFFER = 1.6 m. They should never physically overlap
    // (bodies touch at 1.0 m). 0.5 m is a generous lower bound —
    // separation should prevent actual body contact.
    CHECK(min_distance > 0.5f);
}

TEST_CASE("behavioral — agent pinned at origin escalates L1 then L2 within bounded ticks") {
    FlowFieldServerImpl s;
    s.configure_map(32, 32, 2.0f, -32.0f, -32.0f);
    s.set_agent_radius(0, 0.5f);
    SteeringKernelImpl k;
    k.set_flow_field_server(&s);
    FieldId fid = s.build_field(godot::Vector3(20, 0, 20), 0);
    REQUIRE(fid != INVALID_FIELD_ID);
    AgentHandle h = k.register_agent(501, 0, 0.5f, 5.0f, 20.0f, 8.0f);
    k.set_agent_target(h, 1, fid, 0);
    int idx = k.test_handle_to_idx(h);

    // Pin at origin every tick — DO NOT integrate velocity into pos.
    // Simulates a truly wedged agent: kernel keeps requesting motion,
    // position never changes, stuck detector escalates.
    int l1_fire_tick = -1;
    int l2_fire_tick = -1;
    for (int t = 0; t < 60; ++t) {
        k.set_agent_pos(h, godot::Vector3(0, 0, 0));
        k.tick(0.1f);
        if (l1_fire_tick < 0 && k.test_get_stuck_level(idx) >= 1) {
            l1_fire_tick = t;
        }
        if (l2_fire_tick < 0 && k.test_get_stuck_level(idx) >= 2) {
            l2_fire_tick = t;
            break;
        }
    }
    INFO("L1 fired at tick " << l1_fire_tick << ", L2 fired at tick " << l2_fire_tick);
    // L1 fires after STUCK_WINDOW_TICKS (20) stationary samples, on the
    // tick where the window is full and ratio < threshold. The first tick
    // recorded is tick 0 (set_agent_pos sets pos, then tick runs and
    // records displacement = 0). Window fills at tick 19, L1 checks
    // fire at tick 20. Allow up to 25 for floating-point / ordering slack.
    CHECK(l1_fire_tick >= 0);
    CHECK(l1_fire_tick <= 25);
    // L2 fires after:
    //   L1 at tick ~20
    //   + STUCK_LEVEL1_PUSHOUT_DURATION_TICKS (10 ticks)
    //   + STUCK_LEVEL1_COOLDOWN_SEC / DELTA (1.5 s / 0.1 s = 15 ticks of cooldown)
    //   + 1 tick for L2 check to run
    //   Total ≈ 20 + 10 + 15 + 1 = 46 ticks. Allow up to 55 for slack.
    CHECK(l2_fire_tick >= 0);
    CHECK(l2_fire_tick <= 55);
    // Exactly one path_unreachable event for the single agent.
    CHECK(k.test_pending_failure_count() == 1);
}

TEST_CASE("behavioral — mixed 20-unit flock arrives cohesively, no stuck, no severe wiggle") {
    FlowFieldServerImpl s;
    s.configure_map(80, 80, 2.0f, -80.0f, -80.0f);
    s.set_agent_radius(0, 0.5f);
    SteeringKernelImpl k;
    k.set_flow_field_server(&s);
    godot::Vector3 goal(40, 0, 0);
    FieldId fid = s.build_field(goal, 0);
    REQUIRE(fid != INVALID_FIELD_ID);

    // 20 mixed agents: 4 distinct profiles × 5 of each. Spawn in a
    // 4×5 starting grid covering ~12m × 8m (Z × X) — like a real
    // multi-squad selection.
    struct GameplayAgentSpec {
        godot::Vector3 spawn_pos;
        float radius;
        float max_speed;
        float max_accel;
        float max_turn_rate;
    };
    std::vector<GameplayAgentSpec> specs;
    // "Hound" — medium, moderate speed
    for (int i = 0; i < 5; ++i) specs.push_back({godot::Vector3(-30.0f, 0.0f, -6.0f + static_cast<float>(i) * 3.0f), 0.5f, 5.0f, 20.0f, 8.0f});
    // "Ratchet" — small, fast
    for (int i = 0; i < 5; ++i) specs.push_back({godot::Vector3(-32.0f, 0.0f, -6.0f + static_cast<float>(i) * 3.0f), 0.4f, 7.0f, 28.0f, 10.0f});
    // "Bulwark" — large, slow
    for (int i = 0; i < 5; ++i) specs.push_back({godot::Vector3(-28.0f, 0.0f, -6.0f + static_cast<float>(i) * 3.0f), 1.0f, 3.0f, 12.0f, 5.0f});
    // "Rook" — medium-small, fast-ish
    for (int i = 0; i < 5; ++i) specs.push_back({godot::Vector3(-26.0f, 0.0f, -6.0f + static_cast<float>(i) * 3.0f), 0.5f, 6.0f, 24.0f, 9.0f});

    std::vector<AgentHandle> handles;
    for (const GameplayAgentSpec &spec : specs) {
        AgentHandle h = k.register_agent(static_cast<int>(handles.size() + 1000), 0,
                                         spec.radius, spec.max_speed, spec.max_accel, spec.max_turn_rate);
        REQUIRE(h != INVALID_AGENT_HANDLE);
        k.set_agent_target(h, 1 /*group_id*/, fid, 0);
        k.set_agent_pos(h, spec.spawn_pos);
        handles.push_back(h);
    }

    constexpr float DELTA = 0.1f;
    constexpr int TICKS = 400;  // 40s — slower units (bulwark 3 m/s) take longest
    float lateral_velocity_sum_sq = 0.0f;
    int sample_count = 0;
    for (int t = 0; t < TICKS; ++t) {
        k.tick(DELTA);
        for (AgentHandle h : handles) {
            int idx = k.test_handle_to_idx(h);
            godot::Vector3 cur_pos = k.test_get_pos(idx);
            godot::Vector3 v = k.get_velocity(h);
            k.set_agent_pos(h, cur_pos + v * DELTA);
            // Sample lateral velocity in steady-state window (ticks 80..280).
            if (t >= 80 && t < 280) {
                lateral_velocity_sum_sq += v.z * v.z;
                sample_count += 1;
            }
        }
    }

    // No agent should be HALTED.
    int halted_count = 0;
    for (AgentHandle h : handles) {
        if (k.test_get_stuck_level(k.test_handle_to_idx(h)) >= 2) halted_count += 1;
    }
    INFO("Halted at end: " << halted_count << " / 20");
    CHECK(halted_count == 0);

    // Most agents reach the goal area. Bulwarks are slow; allow a few
    // stragglers.
    int near_goal = 0;
    for (AgentHandle h : handles) {
        godot::Vector3 p = k.test_get_pos(k.test_handle_to_idx(h));
        if ((p - goal).length() < 20.0f) near_goal += 1;
    }
    INFO("Near goal (< 20m) at end: " << near_goal << " / 20");
    CHECK(near_goal >= 16);

    // Lateral RMS during steady-state — mixed flock with varied speeds
    // generates more separation activity than uniform single-class. 1.2
    // m/s is a generous bar; the 5-agent same-class test measured 0.26.
    float lateral_rms = std::sqrt(lateral_velocity_sum_sq / std::max(sample_count, 1));
    INFO("Lateral RMS over steady-state: " << lateral_rms << " m/s");
    CHECK(lateral_rms < 1.2f);
}

TEST_CASE("behavioral — mixed 20-unit attack on single target shows lateral spread") {
    FlowFieldServerImpl s;
    s.configure_map(80, 80, 2.0f, -80.0f, -80.0f);
    s.set_agent_radius(0, 0.5f);
    SteeringKernelImpl k;
    k.set_flow_field_server(&s);
    godot::Vector3 goal(30, 0, 0);
    FieldId fid = s.build_field(goal, 0);
    REQUIRE(fid != INVALID_FIELD_ID);

    struct GameplayAgentSpec {
        godot::Vector3 spawn_pos;
        float radius;
        float max_speed;
        float max_accel;
        float max_turn_rate;
    };
    std::vector<GameplayAgentSpec> specs;
    for (int i = 0; i < 5; ++i) specs.push_back({godot::Vector3(-30.0f, 0.0f, -6.0f + static_cast<float>(i) * 3.0f), 0.5f, 5.0f, 20.0f, 8.0f});
    for (int i = 0; i < 5; ++i) specs.push_back({godot::Vector3(-32.0f, 0.0f, -6.0f + static_cast<float>(i) * 3.0f), 0.4f, 7.0f, 28.0f, 10.0f});
    for (int i = 0; i < 5; ++i) specs.push_back({godot::Vector3(-28.0f, 0.0f, -6.0f + static_cast<float>(i) * 3.0f), 1.0f, 3.0f, 12.0f, 5.0f});
    for (int i = 0; i < 5; ++i) specs.push_back({godot::Vector3(-26.0f, 0.0f, -6.0f + static_cast<float>(i) * 3.0f), 0.5f, 6.0f, 24.0f, 9.0f});

    std::vector<AgentHandle> handles;
    for (const GameplayAgentSpec &spec : specs) {
        AgentHandle h = k.register_agent(static_cast<int>(handles.size() + 2000), 0,
                                         spec.radius, spec.max_speed, spec.max_accel, spec.max_turn_rate);
        REQUIRE(h != INVALID_AGENT_HANDLE);
        k.set_agent_target(h, 1, fid, 0);
        k.set_agent_pos(h, spec.spawn_pos);
        handles.push_back(h);
    }

    constexpr float DELTA = 0.1f;
    constexpr int TICKS = 500;
    for (int t = 0; t < TICKS; ++t) {
        k.tick(DELTA);
        for (AgentHandle h : handles) {
            int idx = k.test_handle_to_idx(h);
            godot::Vector3 cur_pos = k.test_get_pos(idx);
            godot::Vector3 v = k.get_velocity(h);
            k.set_agent_pos(h, cur_pos + v * DELTA);
        }
    }

    // Spatial spread of agents close to the goal — what a player sees
    // when ordering 20 units to attack one target.
    float z_min = std::numeric_limits<float>::infinity();
    float z_max = -std::numeric_limits<float>::infinity();
    float x_min = std::numeric_limits<float>::infinity();
    float x_max = -std::numeric_limits<float>::infinity();
    int near_goal_count = 0;
    for (AgentHandle h : handles) {
        godot::Vector3 p = k.test_get_pos(k.test_handle_to_idx(h));
        if ((p - goal).length() < 20.0f) {
            z_min = std::min(z_min, p.z);
            z_max = std::max(z_max, p.z);
            x_min = std::min(x_min, p.x);
            x_max = std::max(x_max, p.x);
            near_goal_count += 1;
        }
    }
    float z_spread = z_max - z_min;
    float x_spread = x_max - x_min;
    INFO("Near goal: " << near_goal_count << " / 20, Z spread: " << z_spread << "m, X spread: " << x_spread << "m");

    CHECK(near_goal_count >= 14);  // bulwarks are slow; allow stragglers
    // 20 units converging on one cell currently clump because there's
    // no attack-spread feature — they all SEEK the same point. Without
    // attack-spread the measured Z spread is ~2.3m (separation-only).
    // 2.0m proves they don't stack literally on top of each other.
    // Adjust this threshold UP once attack-spread lands; it should hit 10-15m.
    CHECK(z_spread >= 2.0f);
}

TEST_CASE("behavioral — attack-spread via per-squad arc offsets produces wide fan-out") {
    // Mirrors what GroupAura._setup_attack_spread does: each squad gets its
    // own flow field at a laterally-offset goal position. This test exercises
    // the math independently of GDScript to verify spread is achieved.
    FlowFieldServerImpl s;
    s.configure_map(80, 80, 2.0f, -80.0f, -80.0f);
    s.set_agent_radius(0, 0.5f);
    SteeringKernelImpl k;
    k.set_flow_field_server(&s);
    godot::Vector3 target(30, 0, 0);

    // Approach direction: from (-30,0,0) → (30,0,0) = +X. Perp = (0,0,-1).
    godot::Vector3 perp(0, 0, -1);
    constexpr int N_SQUADS = 5;
    // spread_half_width = clamp(3 + 5*1.5, 4, 18) = 10.5
    float spread_half_width = 3.0f + static_cast<float>(N_SQUADS) * 1.5f;  // 10.5

    std::vector<AgentHandle> handles;
    for (int i = 0; i < N_SQUADS; ++i) {
        float lateral_t = static_cast<float>(i) / static_cast<float>(N_SQUADS - 1) * 2.0f - 1.0f;
        godot::Vector3 squad_dest = target + perp * (lateral_t * spread_half_width);
        FieldId fid = s.build_field(squad_dest, 0);
        REQUIRE(fid != INVALID_FIELD_ID);
        AgentHandle h = k.register_agent(i + 5000, 0, 0.5f, 5.0f, 20.0f, 8.0f);
        REQUIRE(h != INVALID_AGENT_HANDLE);
        k.set_agent_target(h, 1, fid, 0);
        k.set_agent_pos(h, godot::Vector3(-30.0f, 0.0f, static_cast<float>(i - 2) * 2.0f));
        handles.push_back(h);
    }

    constexpr float DELTA = 0.1f;
    constexpr int TICKS = 400;
    for (int t = 0; t < TICKS; ++t) {
        k.tick(DELTA);
        for (AgentHandle h : handles) {
            int idx = k.test_handle_to_idx(h);
            k.set_agent_pos(h, k.test_get_pos(idx) + k.get_velocity(h) * DELTA);
        }
    }

    float z_min = std::numeric_limits<float>::infinity();
    float z_max = -std::numeric_limits<float>::infinity();
    for (AgentHandle h : handles) {
        godot::Vector3 p = k.test_get_pos(k.test_handle_to_idx(h));
        z_min = std::min(z_min, p.z);
        z_max = std::max(z_max, p.z);
    }
    float z_spread = z_max - z_min;
    INFO("Z spread with attack-spread: " << z_spread << "m (expected >= 15m for 5 squads × 10.5m half-width)");
    // 5 squads × 10.5m half-width = 21m max possible. Real spread will be
    // less due to cohesion + starting clustering. 15m is a robust threshold
    // proving the arc-offset math is working end-to-end.
    CHECK(z_spread >= 15.0f);
}

TEST_CASE("convoy speed cap — mixed-speed group throttles to slowest member") {
    FlowFieldServerImpl s;
    s.configure_map(80, 80, 2.0f, -80.0f, -80.0f);
    s.set_agent_radius(0, 0.5f);
    SteeringKernelImpl k;
    k.set_flow_field_server(&s);
    FieldId fid = s.build_field(godot::Vector3(50, 0, 0), 0);
    REQUIRE(fid != INVALID_FIELD_ID);

    // 3 agents: fast (10 m/s), medium (5 m/s), slow (3 m/s).
    // No cap: fast unit reaches goal first, formation stretches.
    // With cap set to 3 m/s: all three move at slow's pace, formation
    // stays compact.
    AgentHandle h_fast = k.register_agent(1, 0, 0.5f, 10.0f, 40.0f, 8.0f);
    AgentHandle h_med  = k.register_agent(2, 0, 0.5f, 5.0f, 20.0f, 8.0f);
    AgentHandle h_slow = k.register_agent(3, 0, 0.5f, 3.0f, 12.0f, 8.0f);
    k.set_agent_target(h_fast, 1, fid, 0);
    k.set_agent_target(h_med, 1, fid, 0);
    k.set_agent_target(h_slow, 1, fid, 0);
    k.set_agent_pos(h_fast, godot::Vector3(-30.0f, 0.0f, -2.0f));
    k.set_agent_pos(h_med, godot::Vector3(-30.0f, 0.0f, 0.0f));
    k.set_agent_pos(h_slow, godot::Vector3(-30.0f, 0.0f, 2.0f));

    // Apply convoy cap = slow's speed.
    k.set_agent_speed_cap(h_fast, 3.0f);
    k.set_agent_speed_cap(h_med, 3.0f);
    k.set_agent_speed_cap(h_slow, 3.0f);

    constexpr float DELTA = 0.1f;
    constexpr int TICKS = 200;
    for (int t = 0; t < TICKS; ++t) {
        k.tick(DELTA);
        for (AgentHandle h : {h_fast, h_med, h_slow}) {
            int idx = k.test_handle_to_idx(h);
            k.set_agent_pos(h, k.test_get_pos(idx) + k.get_velocity(h) * DELTA);
        }
    }

    // After 200 ticks (20s at 10 Hz × 3 m/s = ~60m travel), all three
    // should be near each other along X. With no cap, the fast one
    // would be ~140m further than the slow one.
    float x_fast = k.test_get_pos(k.test_handle_to_idx(h_fast)).x;
    float x_med  = k.test_get_pos(k.test_handle_to_idx(h_med)).x;
    float x_slow = k.test_get_pos(k.test_handle_to_idx(h_slow)).x;
    float spread_x = std::max({x_fast, x_med, x_slow}) - std::min({x_fast, x_med, x_slow});
    INFO("X spread under convoy cap: " << spread_x << "m (no cap would be ~140m)");
    CHECK(spread_x < 10.0f);  // tight column; would be 100m+ without the cap
}

TEST_CASE("convoy speed cap — INF cap means no throttle (fast unit pulls ahead)") {
    FlowFieldServerImpl s;
    s.configure_map(80, 80, 2.0f, -80.0f, -80.0f);
    s.set_agent_radius(0, 0.5f);
    SteeringKernelImpl k;
    k.set_flow_field_server(&s);
    FieldId fid = s.build_field(godot::Vector3(50, 0, 0), 0);
    REQUIRE(fid != INVALID_FIELD_ID);

    AgentHandle h_fast = k.register_agent(1, 0, 0.5f, 10.0f, 40.0f, 8.0f);
    AgentHandle h_slow = k.register_agent(3, 0, 0.5f, 3.0f, 12.0f, 8.0f);
    k.set_agent_target(h_fast, 1, fid, 0);
    k.set_agent_target(h_slow, 1, fid, 0);
    k.set_agent_pos(h_fast, godot::Vector3(-30.0f, 0.0f, -2.0f));
    k.set_agent_pos(h_slow, godot::Vector3(-30.0f, 0.0f, 2.0f));
    // No cap (default INF).

    constexpr float DELTA = 0.1f;
    for (int t = 0; t < 50; ++t) {
        k.tick(DELTA);
        for (AgentHandle h : {h_fast, h_slow}) {
            int idx = k.test_handle_to_idx(h);
            k.set_agent_pos(h, k.test_get_pos(idx) + k.get_velocity(h) * DELTA);
        }
    }
    float spread = k.test_get_pos(k.test_handle_to_idx(h_fast)).x
                 - k.test_get_pos(k.test_handle_to_idx(h_slow)).x;
    INFO("X spread without convoy cap (50 ticks): " << spread << "m");
    // Without cap, after ~5s the fast unit (10 m/s × 5s = ~50m max) should
    // be at least 15m ahead of the slow one (3 m/s × 5s = ~15m).
    CHECK(spread >= 15.0f);
}

TEST_CASE("behavioral — two opposing 10-unit groups cross paths without permanent jam") {
    FlowFieldServerImpl s;
    s.configure_map(80, 80, 2.0f, -80.0f, -80.0f);
    s.set_agent_radius(0, 0.5f);
    SteeringKernelImpl k;
    k.set_flow_field_server(&s);
    // Group A heads east, group B heads west — opposing paths through
    // a shared region.
    FieldId fid_a = s.build_field(godot::Vector3(40, 0, 0), 0);
    FieldId fid_b = s.build_field(godot::Vector3(-40, 0, 0), 0);
    REQUIRE(fid_a != INVALID_FIELD_ID);
    REQUIRE(fid_b != INVALID_FIELD_ID);

    struct GameplayAgentSpec {
        godot::Vector3 spawn_pos;
        float radius;
        float max_speed;
        float max_accel;
        float max_turn_rate;
    };

    // Group A: 10 mixed at x=-30, varied z
    std::vector<GameplayAgentSpec> specs_a;
    for (int i = 0; i < 3; ++i) specs_a.push_back({godot::Vector3(-30.0f, 0.0f, -4.0f + static_cast<float>(i) * 2.0f), 0.5f, 5.0f, 20.0f, 8.0f});
    for (int i = 0; i < 3; ++i) specs_a.push_back({godot::Vector3(-32.0f, 0.0f, -4.0f + static_cast<float>(i) * 2.0f), 0.4f, 7.0f, 28.0f, 10.0f});
    for (int i = 0; i < 2; ++i) specs_a.push_back({godot::Vector3(-28.0f, 0.0f, -2.0f + static_cast<float>(i) * 2.0f), 1.0f, 3.0f, 12.0f, 5.0f});
    for (int i = 0; i < 2; ++i) specs_a.push_back({godot::Vector3(-26.0f, 0.0f, -2.0f + static_cast<float>(i) * 2.0f), 0.5f, 6.0f, 24.0f, 9.0f});

    // Group B: same composition at x=+30
    std::vector<GameplayAgentSpec> specs_b;
    for (int i = 0; i < 3; ++i) specs_b.push_back({godot::Vector3(30.0f, 0.0f, -4.0f + static_cast<float>(i) * 2.0f), 0.5f, 5.0f, 20.0f, 8.0f});
    for (int i = 0; i < 3; ++i) specs_b.push_back({godot::Vector3(32.0f, 0.0f, -4.0f + static_cast<float>(i) * 2.0f), 0.4f, 7.0f, 28.0f, 10.0f});
    for (int i = 0; i < 2; ++i) specs_b.push_back({godot::Vector3(28.0f, 0.0f, -2.0f + static_cast<float>(i) * 2.0f), 1.0f, 3.0f, 12.0f, 5.0f});
    for (int i = 0; i < 2; ++i) specs_b.push_back({godot::Vector3(26.0f, 0.0f, -2.0f + static_cast<float>(i) * 2.0f), 0.5f, 6.0f, 24.0f, 9.0f});

    std::vector<AgentHandle> handles_a;
    for (const GameplayAgentSpec &spec : specs_a) {
        AgentHandle h = k.register_agent(static_cast<int>(handles_a.size() + 3000), 0,
                                         spec.radius, spec.max_speed, spec.max_accel, spec.max_turn_rate);
        k.set_agent_target(h, 1 /*group A*/, fid_a, 0);
        k.set_agent_pos(h, spec.spawn_pos);
        handles_a.push_back(h);
    }
    std::vector<AgentHandle> handles_b;
    for (const GameplayAgentSpec &spec : specs_b) {
        AgentHandle h = k.register_agent(static_cast<int>(handles_b.size() + 4000), 0,
                                         spec.radius, spec.max_speed, spec.max_accel, spec.max_turn_rate);
        k.set_agent_target(h, 2 /*group B — different group_id, no cohesion w/ A*/, fid_b, 0);
        k.set_agent_pos(h, spec.spawn_pos);
        handles_b.push_back(h);
    }

    constexpr float DELTA = 0.1f;
    constexpr int TICKS = 400;
    for (int t = 0; t < TICKS; ++t) {
        k.tick(DELTA);
        for (AgentHandle h : handles_a) {
            int idx = k.test_handle_to_idx(h);
            k.set_agent_pos(h, k.test_get_pos(idx) + k.get_velocity(h) * DELTA);
        }
        for (AgentHandle h : handles_b) {
            int idx = k.test_handle_to_idx(h);
            k.set_agent_pos(h, k.test_get_pos(idx) + k.get_velocity(h) * DELTA);
        }
    }

    // No agent permanently stuck (HALTED).
    int halted_a = 0, halted_b = 0;
    for (AgentHandle h : handles_a) if (k.test_get_stuck_level(k.test_handle_to_idx(h)) >= 2) halted_a += 1;
    for (AgentHandle h : handles_b) if (k.test_get_stuck_level(k.test_handle_to_idx(h)) >= 2) halted_b += 1;
    INFO("Halted: A=" << halted_a << " B=" << halted_b);
    // Crossing two flocks IS a stressful test; allow up to 2 stuck per group
    // (the centermost agents may get pushed back-and-forth long enough).
    CHECK(halted_a <= 2);
    CHECK(halted_b <= 2);

    // Most of each group reached their respective goal.
    int reached_a = 0, reached_b = 0;
    for (AgentHandle h : handles_a) if (k.test_get_pos(k.test_handle_to_idx(h)).x > 25.0f) reached_a += 1;
    for (AgentHandle h : handles_b) if (k.test_get_pos(k.test_handle_to_idx(h)).x < -25.0f) reached_b += 1;
    INFO("Reached A>+25: " << reached_a << " / 10, B<-25: " << reached_b << " / 10");
    CHECK(reached_a >= 7);
    CHECK(reached_b >= 7);
}
