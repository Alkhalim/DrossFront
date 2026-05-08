#include "cost_grid.h"
#include <algorithm>
#include <cmath>

namespace drossfront {

CostGrid::CostGrid(int width, int height, float cell_size, float origin_x, float origin_z)
    : width_(width), height_(height), cell_size_(cell_size),
      origin_x_(origin_x), origin_z_(origin_z),
      cells_(static_cast<size_t>(width * height), COST_OPEN),
      cell_y_(static_cast<size_t>(width * height), 0.0f) {}

int CostGrid::cell_of(float world_x, float world_z) const {
    // floor() (not int truncation) so negative world coordinates map to negative
    // cells — int truncation rounds toward zero, leaving e.g. world_x=-0.5
    // mapped to cx=0 which falsely passes the in-bounds check.
    int cx = static_cast<int>(std::floor((world_x - origin_x_) / cell_size_));
    int cz = static_cast<int>(std::floor((world_z - origin_z_) / cell_size_));
    if (cx < 0 || cx >= width_ || cz < 0 || cz >= height_) return -1;
    return cz * width_ + cx;
}

void CostGrid::mark_obstacle(godot::AABB aabb, float dilation_radius, bool blocked) {
    float min_x = aabb.position.x - dilation_radius;
    float min_z = aabb.position.z - dilation_radius;
    float max_x = aabb.position.x + aabb.size.x + dilation_radius;
    float max_z = aabb.position.z + aabb.size.z + dilation_radius;
    // floor() for the lower bound (so partial overlap on a cell still includes
    // it) and ceil() - 1 for the upper bound (so an AABB whose right edge falls
    // exactly on a cell boundary does NOT include that next cell).
    int x0 = std::max(0,            static_cast<int>(std::floor((min_x - origin_x_) / cell_size_)));
    int x1 = std::min(width_  - 1,  static_cast<int>(std::ceil ((max_x - origin_x_) / cell_size_)) - 1);
    int z0 = std::max(0,            static_cast<int>(std::floor((min_z - origin_z_) / cell_size_)));
    int z1 = std::min(height_ - 1,  static_cast<int>(std::ceil ((max_z - origin_z_) / cell_size_)) - 1);
    uint8_t v = blocked ? COST_BLOCKED : COST_OPEN;
    for (int cz = z0; cz <= z1; ++cz) {
        for (int cx = x0; cx <= x1; ++cx) {
            cells_[cz * width_ + cx] = v;
        }
    }
}

void CostGrid::mark_soft_cost(godot::AABB aabb, float dilation_radius, uint8_t cost) {
    if (cost == COST_BLOCKED) return; // caller error; use mark_obstacle
    float min_x = aabb.position.x - dilation_radius;
    float min_z = aabb.position.z - dilation_radius;
    float max_x = aabb.position.x + aabb.size.x + dilation_radius;
    float max_z = aabb.position.z + aabb.size.z + dilation_radius;
    int x0 = std::max(0,            static_cast<int>(std::floor((min_x - origin_x_) / cell_size_)));
    int x1 = std::min(width_  - 1,  static_cast<int>(std::ceil ((max_x - origin_x_) / cell_size_)) - 1);
    int z0 = std::max(0,            static_cast<int>(std::floor((min_z - origin_z_) / cell_size_)));
    int z1 = std::min(height_ - 1,  static_cast<int>(std::ceil ((max_z - origin_z_) / cell_size_)) - 1);
    for (int cz = z0; cz <= z1; ++cz) {
        for (int cx = x0; cx <= x1; ++cx) {
            // Soft cost only applies to currently-open cells.
            uint8_t &c = cells_[cz * width_ + cx];
            if (c == COST_OPEN) c = cost;
        }
    }
}

int CostGrid::nearest_open(int origin_idx, int max_radius_cells) const {
    if (origin_idx < 0 || origin_idx >= cell_count()) return -1;
    if (cells_[origin_idx] == COST_OPEN) return origin_idx;
    int ox = origin_idx % width_;
    int oz = origin_idx / width_;
    for (int r = 1; r <= max_radius_cells; ++r) {
        // Walk the perimeter of a square of radius r around origin.
        for (int dz = -r; dz <= r; ++dz) {
            int cz = oz + dz;
            if (cz < 0 || cz >= height_) continue;
            for (int dx = -r; dx <= r; ++dx) {
                if (std::abs(dx) != r && std::abs(dz) != r) continue; // perimeter only
                int cx = ox + dx;
                if (cx < 0 || cx >= width_) continue;
                int idx = cz * width_ + cx;
                if (cells_[idx] == COST_OPEN) return idx;
            }
        }
    }
    return -1;
}

} // namespace drossfront
