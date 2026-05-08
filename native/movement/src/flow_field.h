#pragma once
#include <cstdint>
#include <vector>
#include <godot_cpp/variant/vector2.hpp>
#include "types.h"
#include "cost_grid.h"

namespace drossfront {

class FlowField {
public:
    static constexpr uint16_t INTEGRATION_INF = 65535;

    FlowField(const CostGrid &grid);

    // Build the field by Dijkstra from goal_cell. Returns true if the goal
    // was a valid open cell. Returns false if the goal is blocked (caller
    // is responsible for snap-to-nearest fallback).
    bool build_from(int goal_cell);

    // Sample flow direction at world XZ. Returns (0,0) if outside grid or
    // sample cell is unreachable from goal.
    godot::Vector2 sample(float world_x, float world_z) const;

    uint16_t integration_at(int cell_idx) const { return integration_[cell_idx]; }
    int goal_cell() const { return goal_cell_; }

private:
    const CostGrid &grid_;
    std::vector<godot::Vector2> flow_;
    std::vector<uint16_t> integration_;
    int goal_cell_;

    void compute_flow_directions();
};

} // namespace drossfront
