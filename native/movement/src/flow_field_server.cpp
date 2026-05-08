#include "flow_field_server.h"
#include <godot_cpp/core/class_db.hpp>

namespace drossfront {

void FlowFieldServer::_bind_methods() {
    using namespace godot;
    ClassDB::bind_method(D_METHOD("configure_map", "grid_w", "grid_h",
                                  "cell_size", "origin_x", "origin_z"),
                         &FlowFieldServer::configure_map);
    ClassDB::bind_method(D_METHOD("set_agent_radius", "agent_class", "radius"),
                         &FlowFieldServer::set_agent_radius);
    ClassDB::bind_method(D_METHOD("build_field", "goal", "agent_class"),
                         &FlowFieldServer::build_field);
    ClassDB::bind_method(D_METHOD("release_field", "id"),
                         &FlowFieldServer::release_field);
    ClassDB::bind_method(D_METHOD("sample", "id", "world_pos"),
                         &FlowFieldServer::sample);
    ClassDB::bind_method(D_METHOD("mark_obstacle", "aabb", "blocked"),
                         &FlowFieldServer::mark_obstacle);
    ClassDB::bind_method(D_METHOD("mark_soft_cost", "aabb", "cost"),
                         &FlowFieldServer::mark_soft_cost);
}

FlowFieldServer::FlowFieldServer() {}
FlowFieldServer::~FlowFieldServer() {}

void FlowFieldServer::configure_map(int grid_w, int grid_h, float cell_size,
                                     float origin_x, float origin_z) {
    // Drop any live fields BEFORE replacing the cost grids: each FlowField
    // holds a `const CostGrid&` to its source grid; replacing the grid
    // without clearing the fields would leave dangling references that
    // would UB on the next sample(). configure_map is intended to be
    // called once at scene start, but this guard makes a re-config safe.
    fields_.clear();
    grid_w_ = grid_w;
    grid_h_ = grid_h;
    cell_size_ = cell_size;
    origin_x_ = origin_x;
    origin_z_ = origin_z;
    for (int c = 0; c < AGENT_CLASS_COUNT; ++c) {
        cost_grids_[c] = std::make_unique<CostGrid>(grid_w, grid_h, cell_size, origin_x, origin_z);
    }
}

void FlowFieldServer::set_agent_radius(int agent_class, float radius) {
    if (agent_class < 0 || agent_class >= AGENT_CLASS_COUNT) return;
    agent_radii_[agent_class] = radius;
}

FieldId FlowFieldServer::build_field(godot::Vector3 goal, int agent_class) {
    if (agent_class < 0 || agent_class >= AGENT_CLASS_COUNT) return INVALID_FIELD_ID;
    if (!cost_grids_[agent_class]) return INVALID_FIELD_ID;
    CostGrid *grid = cost_grids_[agent_class].get();
    int goal_cell = grid->cell_of(goal.x, goal.z);
    if (goal_cell < 0) return INVALID_FIELD_ID;
    if (grid->get(goal_cell) == CostGrid::COST_BLOCKED) {
        // Snap to nearest open cell within ~8 m.
        int snap_radius_cells = static_cast<int>(8.0f / cell_size_) + 1;
        int snapped = grid->nearest_open(goal_cell, snap_radius_cells);
        if (snapped < 0) return INVALID_FIELD_ID;
        goal_cell = snapped;
    }
    auto field = std::make_unique<FlowField>(*grid);
    if (!field->build_from(goal_cell)) return INVALID_FIELD_ID;
    FieldId id = next_field_id_++;
    fields_[id] = FieldEntry{std::move(field), agent_class, goal_cell, false};
    return id;
}

void FlowFieldServer::release_field(FieldId id) {
    fields_.erase(id);
}

godot::Vector2 FlowFieldServer::sample(FieldId id, godot::Vector3 world_pos) {
    auto it = fields_.find(id);
    if (it == fields_.end()) return godot::Vector2();
    if (it->second.dirty) {
        rebuild_field(it->second);
    }
    return it->second.field->sample(world_pos.x, world_pos.z);
}

void FlowFieldServer::mark_obstacle(godot::AABB aabb, bool blocked) {
    for (int c = 0; c < AGENT_CLASS_COUNT; ++c) {
        if (cost_grids_[c]) {
            cost_grids_[c]->mark_obstacle(aabb, agent_radii_[c], blocked);
        }
    }
    for (auto &kv : fields_) kv.second.dirty = true;
}

void FlowFieldServer::mark_soft_cost(godot::AABB aabb, int cost) {
    if (cost < 1 || cost > 254) return;
    for (int c = 0; c < AGENT_CLASS_COUNT; ++c) {
        if (cost_grids_[c]) {
            cost_grids_[c]->mark_soft_cost(aabb, agent_radii_[c], static_cast<uint8_t>(cost));
        }
    }
    for (auto &kv : fields_) kv.second.dirty = true;
}

void FlowFieldServer::rebuild_field(FieldEntry &entry) {
    entry.field = std::make_unique<FlowField>(*cost_grids_[entry.agent_class]);
    entry.field->build_from(entry.goal_cell);
    entry.dirty = false;
}

} // namespace drossfront
