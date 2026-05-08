#pragma once
#include <cstdint>
#include <vector>
#include <godot_cpp/variant/aabb.hpp>
#include "types.h"

namespace drossfront {

class CostGrid {
public:
    static constexpr uint8_t COST_OPEN = 0;
    static constexpr uint8_t COST_BLOCKED = 255;

    CostGrid(int width, int height, float cell_size, float origin_x, float origin_z);

    int width() const { return width_; }
    int height() const { return height_; }
    float cell_size() const { return cell_size_; }
    int cell_count() const { return width_ * height_; }

    // Map world XZ to a cell index. Returns -1 if outside grid bounds.
    int cell_of(float world_x, float world_z) const;

    // Read / write cells.
    uint8_t get(int idx) const { return cells_[idx]; }
    uint8_t get_xy(int cx, int cz) const { return cells_[cz * width_ + cx]; }
    void set(int idx, uint8_t value) { cells_[idx] = value; }

    // Per-cell navmesh Y elevation. Populated by GDScript at server init
    // from NavigationServer3D.map_get_closest_point queries. FlowField's
    // Dijkstra uses this to reject neighbor expansion across large Y
    // deltas (cliffs) while allowing gradual transitions (ramps). Cells
    // whose Y is unset stay at 0.0f, which is fine for flat maps and
    // benign on terrain because ramps still produce small inter-cell
    // deltas that fall under the threshold.
    void set_cell_y(int idx, float y) { cell_y_[idx] = y; }
    float get_cell_y(int idx) const { return cell_y_[idx]; }

    // Mark all cells whose (dilated) center falls inside the AABB. dilation_radius
    // is added to the AABB's XZ extents so the unit's footprint is accounted for.
    void mark_obstacle(godot::AABB aabb, float dilation_radius, bool blocked);

    // Soft cost equivalent of mark_obstacle. Caller picks a value 1-254.
    void mark_soft_cost(godot::AABB aabb, float dilation_radius, uint8_t cost);

    // Find nearest open cell within radius. Returns -1 if none. Used by
    // build_field's snap-to-nearest-cell fast path.
    int nearest_open(int origin_idx, int max_radius_cells) const;

private:
    int width_;
    int height_;
    float cell_size_;
    float origin_x_;
    float origin_z_;
    std::vector<uint8_t> cells_;
    std::vector<float>   cell_y_;  // per-cell navmesh elevation
};

} // namespace drossfront
