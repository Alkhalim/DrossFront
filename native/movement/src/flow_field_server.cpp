#include "flow_field_server.h"
#include <godot_cpp/core/class_db.hpp>

namespace drossfront {

void FlowFieldServer::_bind_methods() {
#ifndef MOVEMENT_NATIVE_TESTS
    // Method binding requires the loaded-extension Godot runtime; in the
    // standalone doctest binary the binding machinery isn't initialized
    // and `bind_method` template instantiation fails to compile against
    // godot::_gde_UnexistingClass. The unit tests don't exercise the
    // GDScript dispatch path anyway — they call C++ methods directly.
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
    ClassDB::bind_method(D_METHOD("set_cell_y_at", "world_pos", "y"),
                         &FlowFieldServer::set_cell_y_at);
#endif
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
    cache_key_to_id_.clear();
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
    // Cache hit: another agent already built a field for this exact
    // (snapped goal cell, agent class) and it's still alive. Bump
    // refcount and hand back the same FieldId. Avoids a redundant
    // ~25k-cell Dijkstra when N units in combat all chase the same
    // target, which is the dominant rebuild driver under high agent
    // counts.
    uint64_t key = cache_key_for(goal_cell, agent_class);
    auto cit = cache_key_to_id_.find(key);
    if (cit != cache_key_to_id_.end()) {
        auto fit = fields_.find(cit->second);
        if (fit != fields_.end()) {
            fit->second.refcount += 1;
            return cit->second;
        }
        // Stale cache entry — fall through and rebuild.
        cache_key_to_id_.erase(cit);
    }
    auto field = std::make_unique<FlowField>(*grid);
    if (!field->build_from(goal_cell)) return INVALID_FIELD_ID;
    FieldId id = next_field_id_++;
    fields_[id] = FieldEntry{std::move(field), agent_class, goal_cell, false, 1};
    cache_key_to_id_[key] = id;
    return id;
}

void FlowFieldServer::release_field(FieldId id) {
    auto it = fields_.find(id);
    if (it == fields_.end()) return;
    it->second.refcount -= 1;
    if (it->second.refcount > 0) return;
    // Last holder dropped — remove from cache and destroy the field.
    uint64_t key = cache_key_for(it->second.goal_cell, it->second.agent_class);
    auto cit = cache_key_to_id_.find(key);
    if (cit != cache_key_to_id_.end() && cit->second == id) {
        cache_key_to_id_.erase(cit);
    }
    fields_.erase(it);
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

void FlowFieldServer::set_cell_y_at(godot::Vector3 world_pos, float y) {
    // Write the elevation into every per-class grid. Y is a property of
    // the terrain, not of the agent class, so all grids share it.
    for (int c = 0; c < AGENT_CLASS_COUNT; ++c) {
        if (!cost_grids_[c]) continue;
        int idx = cost_grids_[c]->cell_of(world_pos.x, world_pos.z);
        if (idx >= 0) {
            cost_grids_[c]->set_cell_y(idx, y);
        }
    }
    // Y is part of the cost surface — flag fields dirty so subsequent
    // samples rebuild against the updated elevation.
    for (auto &kv : fields_) kv.second.dirty = true;
}

} // namespace drossfront
