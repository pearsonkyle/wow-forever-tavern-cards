// tavern-trace: the reference recorder for the Lua engine port.
//
// It links jankcraft's headless engine (simcore + tc, read-only from JANKCRAFT) and plays seeded
// matches with a seeded random policy, writing one JSON line per decision:
//
//   {"t":"match", "seed", "rulesVersion", "families":[a,b], "decks":[[ids],[ids]]}
//   {"t":"step", "ply", "v", "decider", "moves":[{"action","desc","cards","payload"}], "chosen", "state"}
//   {"t":"end", "plies", "terminal", "reason", "state"}
//
// The Lua engine replays `decks` + `seed`, applies the same `chosen` indices, and must produce the
// same move list and the same state at every step.
//
// Usage: tavern-trace --data DIR [--seed N] [--matches N] [--pool FILE] [--max-plies N] [--no-state]
//        tavern-trace --data DIR --dump-programs FILE --dump-cards FILE
//
// --dump-programs writes programs.json as the engine holds it AFTER loading: grammar-tree cards
// lowered to their flat effect lists, which is the runtime ABI the Lua engine ports.
// --dump-cards writes every CardDef the engine knows (tokens and system cards included) with the
// stats and bitmasks exactly as loaded.

#include "simcore/rng.h"
#include "tc/card.h"
#include "tc/compiler.h"
#include "tc/engine.h"
#include "tc/loader.h"
#include "tc/version.h"

#include <algorithm>
#include <cstdint>
#include <cstdlib>
#include <fstream>
#include <iostream>
#include <set>
#include <string>
#include <vector>

namespace
{

std::string quote(std::string const& s)
{
    std::string out = "\"";
    for (unsigned char c : s)
    {
        switch (c)
        {
            case '"':  out += "\\\""; break;
            case '\\': out += "\\\\"; break;
            case '\n': out += "\\n"; break;
            case '\r': out += "\\r"; break;
            case '\t': out += "\\t"; break;
            default:
                if (c < 0x20)
                {
                    char buf[8];
                    std::snprintf(buf, sizeof(buf), "\\u%04x", c);
                    out += buf;
                }
                else
                    out += static_cast<char>(c);
        }
    }
    return out + "\"";
}

// jankcraft's build_deck (src/tc/ai/deck.cpp) with an optional pool filter, so a trace can be
// limited to the cards the Lua engine implements so far. Same ordering and RNG use as the original.
std::vector<std::string> build_deck(tc::Catalogue const& catalogue, tc::Family family, uint64_t seed,
                                    std::set<std::string> const* pool_filter)
{
    struct Entry
    {
        std::string id;
        bool legendary = false;
    };

    std::vector<Entry> pool;
    for (tc::CardDef const* def : catalogue.all())
    {
        if (def == nullptr || !def->implemented || !def->collectible || !def->droppable)
            continue;
        if (def->id == tc::Catalogue::coin_id())
            continue;
        if (def->family != family && def->family != tc::Family::NEUTRAL)
            continue;
        if (pool_filter != nullptr && pool_filter->count(def->id) == 0)
            continue;
        pool.push_back(Entry{def->id, def->rarity == tc::Rarity::LEGENDARY});
    }
    std::sort(pool.begin(), pool.end(), [](Entry const& a, Entry const& b) { return a.id < b.id; });

    int capacity = 0;
    for (Entry const& entry : pool)
        capacity += entry.legendary ? 1 : 2;
    if (capacity < 30)
        return {};

    simcore::Rng rng(seed);
    rng.shuffle(pool);

    std::vector<std::string> deck;
    for (Entry const& entry : pool)
    {
        int const copies = entry.legendary ? 1 : 2;
        for (int i = 0; i < copies && deck.size() < 30; ++i)
            deck.push_back(entry.id);
        if (deck.size() >= 30)
            break;
    }
    return deck.size() == 30 ? deck : std::vector<std::string>{};
}

std::string id_list(std::vector<std::string> const& ids)
{
    std::string out = "[";
    for (std::size_t i = 0; i < ids.size(); ++i)
        out += (i ? "," : "") + quote(ids[i]);
    return out + "]";
}

// The random policy: uniform over legal moves, but conceding is only taken when it is the sole
// option, otherwise most traces would end on ply one.
int choose(simcore::Rng& policy, std::vector<simcore::Move> const& moves)
{
    std::vector<int> candidates;
    for (std::size_t i = 0; i < moves.size(); ++i)
        if (moves[i].action != "concede")
            candidates.push_back(static_cast<int>(i));
    if (candidates.empty())
        return 0;
    return candidates[static_cast<std::size_t>(policy.int_below(static_cast<int>(candidates.size())))];
}

}  // namespace

int main(int argc, char** argv)
{
    std::string data = "data";
    std::string pool_path;
    uint64_t seed = 1;
    int matches = 1;
    int max_plies = 3000;
    bool with_state = true;
    std::string dump_path;
    std::string cards_path;

    for (int i = 1; i < argc; ++i)
    {
        std::string const arg = argv[i];
        auto next = [&]() -> std::string {
            if (i + 1 >= argc)
            {
                std::cerr << "tavern-trace: " << arg << " needs a value\n";
                std::exit(2);
            }
            return argv[++i];
        };
        if (arg == "--data")
            data = next();
        else if (arg == "--pool")
            pool_path = next();
        else if (arg == "--seed")
            seed = std::strtoull(next().c_str(), nullptr, 10);
        else if (arg == "--matches")
            matches = std::atoi(next().c_str());
        else if (arg == "--max-plies")
            max_plies = std::atoi(next().c_str());
        else if (arg == "--dump-cards")
            cards_path = next();
        else if (arg == "--dump-programs")
            dump_path = next();
        else if (arg == "--no-state")
            with_state = false;
        else
        {
            std::cerr << "tavern-trace: unknown argument '" << arg << "'\n";
            return 2;
        }
    }

    tc::Catalogue catalogue;
    tc::LoadReport const load = tc::load_catalogue(catalogue, data + "/catalogue.json");
    if (load.fatal)
    {
        std::cerr << "tavern-trace: " << load.error << "\n";
        return 2;
    }
    tc::load_programs(catalogue, data + "/programs.json");
    catalogue.install_system_cards();

    if (!dump_path.empty() || !cards_path.empty())
    {
        if (!dump_path.empty())
        {
            std::ofstream out(dump_path);
            out << tc::programs_json(catalogue, tc::kRulesVersion);
            if (!out)
                return 1;
        }
        if (!cards_path.empty())
        {
            std::ofstream out(cards_path);
            out << "[";
            bool first = true;
            for (tc::CardDef const* d : catalogue.all())
            {
                if (d == nullptr)
                    continue;
                out << (first ? "\n" : ",\n") << "{\"id\":" << quote(d->id) << ",\"name\":" << quote(d->name)
                    << ",\"type\":" << quote(tc::card_type_name(d->type))
                    << ",\"family\":" << quote(tc::family_name(d->family))
                    << ",\"rarity\":" << quote(tc::rarity_name(d->rarity))
                    << ",\"school\":" << quote(tc::school_name(d->school))
                    << ",\"cost\":" << d->cost << ",\"attack\":" << d->attack << ",\"health\":" << d->health
                    << ",\"durability\":" << d->durability << ",\"keywords\":" << d->keywords
                    << ",\"races\":" << d->races << ",\"collectible\":" << (d->collectible ? "true" : "false")
                    << ",\"droppable\":" << (d->droppable ? "true" : "false")
                    << ",\"implemented\":" << (d->implemented ? "true" : "false")
                    << ",\"text\":" << quote(d->text) << "}";
                first = false;
            }
            out << "\n]\n";
            if (!out)
                return 1;
        }
        return 0;
    }

    std::set<std::string> pool;
    if (!pool_path.empty())
    {
        std::ifstream in(pool_path);
        if (!in)
        {
            std::cerr << "tavern-trace: cannot read pool " << pool_path << "\n";
            return 2;
        }
        std::string line;
        while (std::getline(in, line))
            if (!line.empty() && line[0] != '#')
                pool.insert(line);
    }

    tc::Family const families[] = {
        tc::Family::WARRIOR, tc::Family::PALADIN, tc::Family::HUNTER, tc::Family::ROGUE,
        tc::Family::PRIEST, tc::Family::SHAMAN, tc::Family::MAGE, tc::Family::WARLOCK,
        tc::Family::DRUID, tc::Family::DEATHKNIGHT, tc::Family::DEMONHUNTER};
    int const family_count = static_cast<int>(sizeof(families) / sizeof(families[0]));

    for (int m = 0; m < matches; ++m)
    {
        uint64_t const match_seed = seed + static_cast<uint64_t>(m);
        simcore::Rng setup(match_seed ^ 0x7ACE7ACEull);

        // Pick two families that can field a legal deck from the pool.
        std::vector<std::string> decks[2];
        tc::Family picked[2] = {tc::Family::NEUTRAL, tc::Family::NEUTRAL};
        for (int seat = 0; seat < 2; ++seat)
        {
            for (int attempt = 0; attempt < 32 && decks[seat].empty(); ++attempt)
            {
                picked[seat] = families[setup.int_below(family_count)];
                decks[seat] = build_deck(catalogue, picked[seat], setup.next(), pool.empty() ? nullptr : &pool);
            }
            if (decks[seat].empty())
            {
                std::cerr << "tavern-trace: the pool cannot build a 30-card deck\n";
                return 1;
            }
        }

        std::unique_ptr<tc::TcEngine> engine = tc::TcEngine::create(catalogue, decks[0], decks[1], match_seed);
        if (!engine)
        {
            std::cerr << "tavern-trace: the engine refused the decks (seed " << match_seed << ")\n";
            return 1;
        }

        std::cout << "{\"t\":\"match\",\"seed\":" << match_seed
                  << ",\"rulesVersion\":" << quote(tc::kRulesVersion)
                  << ",\"families\":[" << quote(tc::family_name(picked[0])) << ","
                  << quote(tc::family_name(picked[1])) << "]"
                  << ",\"decks\":[" << id_list(decks[0]) << "," << id_list(decks[1]) << "]";
        if (with_state)
            std::cout << ",\"state\":" << engine->snapshot_json();
        std::cout << "}\n";

        simcore::Rng policy(match_seed ^ 0x9011C7ull);
        int ply = 0;
        for (; ply < max_plies && !engine->is_terminal(); ++ply)
        {
            std::vector<simcore::Move> const moves = engine->legal_moves();
            if (moves.empty())
                break;
            int const chosen = choose(policy, moves);

            std::cout << "{\"t\":\"step\",\"ply\":" << ply << ",\"v\":" << engine->state_version()
                      << ",\"decider\":" << engine->current_player() << ",\"moves\":[";
            for (std::size_t i = 0; i < moves.size(); ++i)
            {
                simcore::Move const& mv = moves[i];
                std::cout << (i ? "," : "") << "{\"action\":" << quote(mv.action) << ",\"desc\":" << quote(mv.desc)
                          << ",\"cards\":[";
                for (std::size_t c = 0; c < mv.card_ids.size(); ++c)
                    std::cout << (c ? "," : "") << mv.card_ids[c];
                std::cout << "],\"payload\":" << (mv.payload_json.empty() ? "null" : mv.payload_json) << "}";
            }
            std::cout << "],\"chosen\":" << chosen;

            if (!engine->apply_move(chosen))
            {
                std::cout << ",\"error\":" << quote(engine->last_error_name()) << "}\n";
                std::cerr << "tavern-trace: move " << chosen << " refused at ply " << ply << "\n";
                return 1;
            }
            if (with_state)
                std::cout << ",\"state\":" << engine->snapshot_json();
            std::cout << "}\n";
        }

        std::cout << "{\"t\":\"end\",\"plies\":" << ply << ",\"terminal\":" << (engine->is_terminal() ? "true" : "false")
                  << ",\"reason\":" << quote(engine->end_reason()) << "}\n";
    }
    return 0;
}
