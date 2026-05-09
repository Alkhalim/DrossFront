#include "flow_field.h"
#include <algorithm>
#include <queue>
#include <utility>

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
            if (std::abs(n_y - cur_y) > MAX_Y_DELTA) continue;
            // Step cost = neighbor base step + soft cost from grid (scaled down).
            uint32_t step = neighbor_cost[n] + cell_cost;
            uint32_t new_cost = cur_cost + step;
            if (new_cost < integration_[nidx]) {
                integration_[nidx] = static_cast<uint16_t>(std::min<uint32_t>(new_cost, INTEGRATION_INF - 1));
                pq.emplace(new_cost, nidx);
            }
        }
    }

    // Best-effort goal fallback: any cell still at INTEGRATION_INF after
    // Dijkstra is in a different connected component than the goal (cliff
    // gap, isolated pocket, etc.). Run a multi-source BFS from the
    // reachable boundary so those cells get a flow direction toward their
    // nearest reachable cell. A unit standing in such a cell will walk to
    // the closest navigable point instead of stopping in place.
    fill_unreachable_via_bfs();
    compute_flow_directions();
    return true;
}

void FlowField::fill_unreachable_via_bfs() {
    const int W = grid_.width();
    const int H = grid_.height();
    const int N = grid_.cell_count();
    constexpr int N_NEIGHBORS = 8;
    static constexpr int neighbor_dx[N_NEIGHBORS] = {-1, 0, 1, -1, 1, -1, 0, 1};
    static constexpr int neighbor_dz[N_NEIGHBORS] = {-1,-1,-1, 0, 0, 1, 1, 1};

    // Floor for all unreachable-cell integration values. Must be greater
    // than any plausible reachable-cell integration so that flow at the
    // boundary always points from unreachable INTO reachable. With
    // grid_w=160 and per-step cost ~14, max reachable integration is
    // ~160 * sqrt(2) * 14 ≈ 3171. UNREACHABLE_BASE = 30000 leaves
    // plenty of headroom and budget for BFS depth (max ~256 steps for
    // a full-grid traversal) before we hit INTEGRATION_INF (65535).
    constexpr uint16_t UNREACHABLE_BASE = 30000;

    // Multi-source BFS. Sources: every cell already reachable from the
    // goal (integration < INTEGRATION_INF). The queue stores (idx, depth)
    // where depth is BFS distance from the nearest reachable cell.
    struct Entry { int idx; uint16_t depth; };
    std::queue<Entry> q;
    std::vector<uint8_t> visited(N, 0);
    for (int i = 0; i < N; ++i) {
        if (integration_[i] < INTEGRATION_INF) {
            q.push({i, 0});
            visited[i] = 1;
        }
    }
    while (!q.empty()) {
        auto [cur, depth] = q.front();
        q.pop();
        int cx = cur % W;
        int cz = cur / W;
        uint16_t next_depth = static_cast<uint16_t>(
            std::min<uint32_t>(static_cast<uint32_t>(depth) + 1u,
                               INTEGRATION_INF - UNREACHABLE_BASE - 1u));
        for (int n = 0; n < N_NEIGHBORS; ++n) {
            int nx = cx + neighbor_dx[n];
            int nz = cz + neighbor_dz[n];
            if (nx < 0 || nx >= W || nz < 0 || nz >= H) continue;
            int nidx = nz * W + nx;
            if (visited[nidx]) continue;
            // Don't propagate INTO blocked cells — they should remain
            // unreachable so sample()'s push-out fallback fires for any
            // unit that ends up inside a dilated obstacle.
            if (grid_.get(nidx) == CostGrid::COST_BLOCKED) continue;
            // Note: no Y-delta check here. We WANT cliff-gap cells (which
            // Dijkstra rejected via Y check) to receive a flow direction
            // toward the cliff edge of their own component. The unit will
            // walk to the cliff base in XZ, then physics-collision against
            // the cliff face stops them — which is the "as close as
            // possible" behavior the design calls for.
            visited[nidx] = 1;
            integration_[nidx] = static_cast<uint16_t>(UNREACHABLE_BASE + next_depth);
            q.push({nidx, next_depth});
        }
    }
}

void FlowField::compute_flow_directions() {
    const int W = grid_.width();
    const int H = grid_.height();
    constexpr int N_NEIGHBORS = 8;
    static constexpr int neighbor_dx[N_NEIGHBORS] = {-1, 0, 1, -1, 1, -1, 0, 1};
    static constexpr int neighbor_dz[N_NEIGHBORS] = {-1,-1,-1, 0, 0, 1, 1, 1};
    // Must match the threshold used in build_from()'s Dijkstra. If they
    // diverge, integration is propagated through one set of edges but
    // gradient direction is computed against another, and the field
    // points units across cliffs that Dijkstra rejected.
    constexpr float MAX_Y_DELTA = 1.5f;

    for (int cz = 0; cz < H; ++cz) {
        for (int cx = 0; cx < W; ++cx) {
            int idx = cz * W + cx;
            if (integration_[idx] == INTEGRATION_INF) {
                flow_[idx] = godot::Vector2(); // unreachable
                continue;
            }
            // Pick the neighbor with the lowest integration cost AMONG
            // 3D-traversable neighbors. Without the Y check here, a
            // cliff-edge plateau cell would point flow at the ground
            // cliff-base cell (lower integration via direct path) and
            // units would walk straight off the cliff instead of using
            // the ramp. The Y check enforces "the gradient direction
            // must follow an edge Dijkstra was allowed to traverse".
            float cur_y = grid_.get_cell_y(idx);
            uint16_t best = integration_[idx];
            int best_dx = 0, best_dz = 0;
            for (int n = 0; n < N_NEIGHBORS; ++n) {
                int nx = cx + neighbor_dx[n];
                int nz = cz + neighbor_dz[n];
                if (nx < 0 || nx >= W || nz < 0 || nz >= H) continue;
                int nidx = nz * W + nx;
                if (integration_[nidx] >= best) continue;
                float n_y = grid_.get_cell_y(nidx);
                if (std::abs(n_y - cur_y) > MAX_Y_DELTA) continue;
                best = integration_[nidx];
                best_dx = neighbor_dx[n];
                best_dz = neighbor_dz[n];
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
