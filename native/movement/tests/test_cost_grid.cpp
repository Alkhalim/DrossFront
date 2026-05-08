#include "doctest.h"
#include "../src/cost_grid.h"

using namespace drossfront;

TEST_CASE("CostGrid initial state is all open") {
    CostGrid g(10, 10, 2.0f, 0.0f, 0.0f);
    for (int i = 0; i < g.cell_count(); ++i) {
        CHECK(g.get(i) == CostGrid::COST_OPEN);
    }
}

TEST_CASE("CostGrid::cell_of maps world XZ to cell index") {
    CostGrid g(10, 10, 2.0f, 0.0f, 0.0f);
    // Cell size 2 m, origin 0,0 -> cell (1,1) covers (2..4, 2..4)
    CHECK(g.cell_of(0.5f, 0.5f) == 0);            // (0,0)
    CHECK(g.cell_of(2.5f, 2.5f) == 1 * 10 + 1);   // (1,1)
    CHECK(g.cell_of(-1.0f, 0.0f) == -1);          // outside
    CHECK(g.cell_of(20.5f, 0.0f) == -1);          // outside
}

TEST_CASE("CostGrid::mark_obstacle blocks cells covered by AABB + dilation") {
    CostGrid g(10, 10, 2.0f, 0.0f, 0.0f);
    // AABB at (4,_,4) size (2,_,2) -> covers cells (2,2)..(2,2) without dilation
    godot::AABB aabb(godot::Vector3(4, 0, 4), godot::Vector3(2, 1, 2));
    g.mark_obstacle(aabb, 0.0f, true);
    CHECK(g.get_xy(2, 2) == CostGrid::COST_BLOCKED);
    CHECK(g.get_xy(1, 2) == CostGrid::COST_OPEN);
    CHECK(g.get_xy(3, 3) == CostGrid::COST_OPEN);
}

TEST_CASE("CostGrid::mark_obstacle dilation adds blocked cells around AABB") {
    CostGrid g(10, 10, 2.0f, 0.0f, 0.0f);
    godot::AABB aabb(godot::Vector3(4, 0, 4), godot::Vector3(2, 1, 2));
    g.mark_obstacle(aabb, 2.0f, true); // 1 cell of dilation
    // Dilated AABB covers (2,_,2)..(8,_,8) -> cells (1,1)..(3,3)
    CHECK(g.get_xy(1, 1) == CostGrid::COST_BLOCKED);
    CHECK(g.get_xy(2, 2) == CostGrid::COST_BLOCKED);
    CHECK(g.get_xy(3, 3) == CostGrid::COST_BLOCKED);
    CHECK(g.get_xy(0, 0) == CostGrid::COST_OPEN);
    CHECK(g.get_xy(4, 4) == CostGrid::COST_OPEN);
}

TEST_CASE("CostGrid::nearest_open returns origin if origin is open") {
    CostGrid g(10, 10, 2.0f, 0.0f, 0.0f);
    int idx = 5 * 10 + 5;
    CHECK(g.nearest_open(idx, 4) == idx);
}

TEST_CASE("CostGrid::nearest_open finds adjacent cell when origin blocked") {
    CostGrid g(10, 10, 2.0f, 0.0f, 0.0f);
    int idx = 5 * 10 + 5;
    g.set(idx, CostGrid::COST_BLOCKED);
    int found = g.nearest_open(idx, 4);
    CHECK(found != -1);
    CHECK(found != idx);
    CHECK(g.get(found) == CostGrid::COST_OPEN);
}

TEST_CASE("CostGrid::nearest_open returns -1 when nothing within radius") {
    CostGrid g(10, 10, 2.0f, 0.0f, 0.0f);
    // Block a 3x3 patch around (5,5)
    for (int dz = -1; dz <= 1; ++dz)
        for (int dx = -1; dx <= 1; ++dx)
            g.set((5 + dz) * 10 + (5 + dx), CostGrid::COST_BLOCKED);
    int idx = 5 * 10 + 5;
    CHECK(g.nearest_open(idx, 1) == -1); // radius 1 isn't enough
    CHECK(g.nearest_open(idx, 2) != -1); // radius 2 reaches the open ring
}
