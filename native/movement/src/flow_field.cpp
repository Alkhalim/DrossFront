#include "flow_field.h"
#include <algorithm>
#include <queue>
#include <utility>
#include <godot_cpp/variant/utility_functions.hpp>

namespace drossfront {

FlowField::FlowField(const CostGrid &grid)
    : grid_(grid),
      flow_(grid.cell_count(), godot::Vector2()),
      integration_(grid.cell_count(), INTEGRATION_INF),
      goal_cell_(-1) {}

bool FlowField::build_from(int goal_cell) {
    if (goal_cell < 0 || goal_cell >= grid_.cell_count()) return false;
    if (grid_.get(goal_cell) == CostGrid::COST_BLOCKED) return false;

    goal_cell_ = goal_cell;
    std::fill(integration_.begin(), integration_.end(), INTEGRATION_INF);
    integration_[goal_cell] = 0;

    // Dijkstra with min-heap. Cell cost is grid cost + 1 base step.
    using Entry = std::pair<uint32_t, int>; // (cumulative_cost, cell_idx)
    std::priority_queue<Entry, std::vector<Entry>, std::greater<Entry>> pq;
    pq.emplace(0, goal_cell);

    const int W = grid_.width();
    const int H = grid_.height();
    constexpr int N_NEIGHBORS = 8;
    static constexpr int neighbor_dx[N_NEIGHBORS] = {-1, 0, 1, -1, 1, -1, 0, 1};
    static constexpr int neighbor_dz[N_NEIGHBORS] = {-1,-1,-1, 0, 0, 1, 1, 1};
    static constexpr uint32_t neighbor_cost[N_NEIGHBORS] = {14, 10, 14, 10, 10, 14, 10, 14};
    // Maximum Y delta between adjacent cells before we reject the
    // neighbor expansion as "non-traversable in 3D" (cliff). At 2m
    // cells, a 30° ramp produces ~1.15m Y/cell, a 45° ramp ~2m/cell.
    // A 2m-tall plateau cliff has 2m Y/cell at the edge.
    //
    // 1.5m allows ramps up to ~37° (1.5m rise per 2m run) while
    // blocking cliffs of 2m+ height. If the user's map has ramps
    // steeper than that, raise this. If cliffs are exactly at the
    // threshold height, lower it.
    constexpr float MAX_Y_DELTA = 1.5f;

    int y_rejected_count = 0;
    int y_max_observed_ms = 0; // largest delta observed (mm * 100) for diagnostic
    while (!pq.empty()) {
        auto [cur_cost, cur_idx] = pq.top();
        pq.pop();
        if (cur_cost > integration_[cur_idx]) continue;
        int cx = cur_idx % W;
        int cz = cur_idx / W;
        float cur_y = grid_.get_cell_y(cur_idx);
        for (int n = 0; n < N_NEIGHBORS; ++n) {
            int nx = cx + neighbor_dx[n];
            int nz = cz + neighbor_dz[n];
            if (nx < 0 || nx >= W || nz < 0 || nz >= H) continue;
            int nidx = nz * W + nx;
            uint8_t cell_cost = grid_.get(nidx);
            if (cell_cost == CostGrid::COST_BLOCKED) continue;
            // Y-aware traversability: don't expand across large elevation
            // gaps. A plateau cell at Y=2 next to a ground cell at Y=0
            // shouldn't be reachable in one step (no climbable geometry);
            // ramp cells differ by smaller deltas and stay traversable.
            float n_y = grid_.get_cell_y(nidx);
            float dy = std::abs(n_y - cur_y);
            int dy_cs = static_cast<int>(dy * 100.0f);
            if (dy_cs > y_max_observed_ms) y_max_observed_ms = dy_cs;
            if (dy > MAX_Y_DELTA) {
                ++y_rejected_count;
                continue;
            }
            // Step cost = neighbor base step + soft cost from grid (scaled down).
            uint32_t step = neighbor_cost[n] + cell_cost;
            uint32_t new_cost = cur_cost + step;
            if (new_cost < integration_[nidx]) {
                integration_[nidx] = static_cast<uint16_t>(std::min<uint32_t>(new_cost, INTEGRATION_INF - 1));
                pq.emplace(new_cost, nidx);
            }
        }
    }
    // Diagnostic: how many cell-pair expansions did the Y-delta check
    // reject? If 0 on a map with cliffs, terrain Y data isn't reaching
    // build_from (or all cells share Y, or threshold is too lenient).
    // y_max_observed (in cm) shows the steepest delta seen.
    godot::UtilityFunctions::print("[FlowField] build_from goal=", goal_cell,
                                   " y_rejected=", y_rejected_count,
                                   " y_max_seen_cm=", y_max_observed_ms,
                                   " threshold=", MAX_Y_DELTA);

    compute_flow_directions();
    return true;
}

void FlowField::compute_flow_directions() {
    const int W = grid_.width();
    const int H = grid_.height();
    constexpr int N_NEIGHBORS = 8;
    static constexpr int neighbor_dx[N_NEIGHBORS] = {-1, 0, 1, -1, 1, -1, 0, 1};
    static constexpr int neighbor_dz[N_NEIGHBORS] = {-1,-1,-1, 0, 0, 1, 1, 1};

    for (int cz = 0; cz < H; ++cz) {
        for (int cx = 0; cx < W; ++cx) {
            int idx = cz * W + cx;
            if (integration_[idx] == INTEGRATION_INF) {
                flow_[idx] = godot::Vector2(); // unreachable
                continue;
            }
            // Pick the neighbor with the lowest integration cost.
            uint16_t best = integration_[idx];
            int best_dx = 0, best_dz = 0;
            for (int n = 0; n < N_NEIGHBORS; ++n) {
                int nx = cx + neighbor_dx[n];
                int nz = cz + neighbor_dz[n];
                if (nx < 0 || nx >= W || nz < 0 || nz >= H) continue;
                int nidx = nz * W + nx;
                if (integration_[nidx] < best) {
                    best = integration_[nidx];
                    best_dx = neighbor_dx[n];
                    best_dz = neighbor_dz[n];
                }
            }
            if (best_dx == 0 && best_dz == 0) {
                flow_[idx] = godot::Vector2(); // local minimum (or goal)
            } else {
                godot::Vector2 dir(static_cast<float>(best_dx), static_cast<float>(best_dz));
                flow_[idx] = dir.normalized();
            }
        }
    }
}

godot::Vector2 FlowField::sample(float world_x, float world_z) const {
    int idx = grid_.cell_of(world_x, world_z);
    if (idx < 0) return godot::Vector2();
    godot::Vector2 v = flow_[idx];
    // Clear flow direction → return as-is.
    if (v.length_squared() > 0.0001f) {
        return v;
    }
    // Flow is zero. Three cases:
    //   (a) the cell IS the goal cell (integration == 0)
    //   (b) the cell is a local minimum (rare with our cost discretization)
    //   (c) the cell is BLOCKED (Dijkstra never visited; integration == INF)
    //
    // For (a) the kernel's arrival logic stops the agent — returning (0,0)
    // is correct.
    //
    // For (c), an agent that wandered into a blocked cell (e.g. dilated
    // building boundary, partial cell overlap, or physics push-back) would
    // otherwise be treated as "arrived" and halt at the obstacle. Find the
    // lowest-integration neighbor and return its direction so the agent
    // gets pulled back to navigable terrain.
    if (integration_[idx] >= INTEGRATION_INF) {
        const int W = grid_.width();
        const int H = grid_.height();
        const int cx = idx % W;
        const int cz = idx / W;
        uint16_t best = INTEGRATION_INF;
        int best_dx = 0;
        int best_dz = 0;
        for (int dz_off = -1; dz_off <= 1; ++dz_off) {
            for (int dx_off = -1; dx_off <= 1; ++dx_off) {
                if (dx_off == 0 && dz_off == 0) continue;
                int nx = cx + dx_off;
                int nz = cz + dz_off;
                if (nx < 0 || nx >= W || nz < 0 || nz >= H) continue;
                int nidx = nz * W + nx;
                if (integration_[nidx] < best) {
                    best = integration_[nidx];
                    best_dx = dx_off;
                    best_dz = dz_off;
                }
            }
        }
        if (best < INTEGRATION_INF) {
            godot::Vector2 dir(static_cast<float>(best_dx), static_cast<float>(best_dz));
            return dir.normalized();
        }
    }
    // Goal cell or true local minimum — kernel handles arrival.
    return v;
}

} // namespace drossfront
