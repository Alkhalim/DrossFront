#include "doctest.h"
#include "../src/cost_grid.h"
#include "../src/flow_field.h"

using namespace drossfront;

TEST_CASE("FlowField on open grid: every cell points toward goal") {
    CostGrid g(10, 10, 1.0f, 0.0f, 0.0f);
    FlowField f(g);
    int goal = 5 * 10 + 5;
    REQUIRE(f.build_from(goal));
    // Cell at (0,0) should have flow pointing roughly toward (5,5) -> +x, +z
    auto v = f.sample(0.5f, 0.5f);
    CHECK(v.x > 0.0f);
    CHECK(v.y > 0.0f);
    // Goal cell itself has zero flow.
    auto vg = f.sample(5.5f, 5.5f);
    CHECK(vg.length() == doctest::Approx(0.0f));
}

TEST_CASE("FlowField with wall: integration cost is INF beyond wall") {
    CostGrid g(10, 10, 1.0f, 0.0f, 0.0f);
    // Wall at column x=4, full height
    for (int cz = 0; cz < 10; ++cz) g.set(cz * 10 + 4, CostGrid::COST_BLOCKED);
    FlowField f(g);
    int goal = 5 * 10 + 7; // right side of wall
    REQUIRE(f.build_from(goal));
    // Cell at (0,5) is on the left of the wall — should be unreachable.
    int left_idx = 5 * 10 + 0;
    CHECK(f.integration_at(left_idx) == FlowField::INTEGRATION_INF);
    // Cell at (8,5) is on the right of the wall — should be reachable.
    int right_idx = 5 * 10 + 8;
    CHECK(f.integration_at(right_idx) != FlowField::INTEGRATION_INF);
}

TEST_CASE("FlowField returns false on blocked goal") {
    CostGrid g(10, 10, 1.0f, 0.0f, 0.0f);
    int goal = 5 * 10 + 5;
    g.set(goal, CostGrid::COST_BLOCKED);
    FlowField f(g);
    CHECK_FALSE(f.build_from(goal));
}

TEST_CASE("FlowField soft cost biases path") {
    CostGrid g(10, 10, 1.0f, 0.0f, 0.0f);
    // Soft cost 100 along the direct row from (0,5) to (5,5)
    for (int cx = 1; cx < 5; ++cx) g.set(5 * 10 + cx, 100);
    FlowField f(g);
    int goal = 5 * 10 + 5;
    REQUIRE(f.build_from(goal));
    // Direct row cost should be higher than going around (via row 4 or 6).
    int direct_idx = 5 * 10 + 0;
    int detour_idx = 4 * 10 + 0;
    CHECK(f.integration_at(direct_idx) > f.integration_at(detour_idx));
}
