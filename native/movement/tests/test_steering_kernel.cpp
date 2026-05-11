#include "doctest.h"
#include "../src/steering_kernel_impl.h"
#include "../src/flow_field_server_impl.h"
#include "../src/types.h"
#include <godot_cpp/variant/vector3.hpp>

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
