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
//        tavern-trace --data DIR --dump-programs FILE --dump-cards FILE --dump-abilities FILE
//
// --dump-programs writes programs.json as the engine holds it AFTER loading: grammar-tree cards
// lowered to their flat effect lists, which is the runtime ABI the Lua engine ports.
// --dump-cards writes every CardDef the engine knows (tokens and system cards included) with the
// stats and bitmasks exactly as loaded.
// --dump-abilities writes, for every grammar-compiled card, each ability lowered ON ITS OWN (the
// engine runs those one by one: run_program_effects), plus the trigger -> event-kind table.

#include "simcore/rng.h"
#include "tc/card.h"
#include "tc/compiler.h"
#include "tc/lower.h"
#include "tc/program.h"
#include "simcore/json.h"
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
    std::string abilities_path;
    std::string forced_family;   // --family NAME: both seats play this class (the card sweep)
    std::vector<std::string> prefer;   // --prefer "Name|Name": take a legal play of these cards when offered

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
        else if (arg == "--dump-abilities")
            abilities_path = next();
        else if (arg == "--dump-cards")
            cards_path = next();
        else if (arg == "--dump-programs")
            dump_path = next();
        else if (arg == "--no-state")
            with_state = false;
        else if (arg == "--family")
            forced_family = next();
        else if (arg == "--prefer")
        {
            std::string list = next();
            std::size_t start = 0;
            while (start <= list.size())
            {
                std::size_t const bar = list.find('|', start);
                std::string const name = list.substr(start, bar == std::string::npos ? std::string::npos : bar - start);
                if (!name.empty())
                    prefer.push_back(name);
                if (bar == std::string::npos)
                    break;
                start = bar + 1;
            }
        }
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

    if (!abilities_path.empty())
    {
        std::ofstream out(abilities_path);
        out << "{\"triggerKinds\":{";
        bool first = true;
        for (int i = 0; i < 256; ++i)
        {
            tc::Trigger const t = static_cast<tc::Trigger>(i);
            char const* name = tc::trigger_name(t);
            tc::Trigger back{};
            if (name == nullptr || !tc::trigger_from_name(name, back) || back != t)
                continue;
            out << (first ? "" : ",") << quote(name) << ":" << static_cast<int>(tc::event_kind_from_trigger(t));
            first = false;
        }
        // Trigger enum numbers: PendingChoice::trigger is stored as one in a snapshot.
        out << "},\n\"triggerNumbers\":{";
        first = true;
        for (int i = 0; i < 256; ++i)
        {
            tc::Trigger const t = static_cast<tc::Trigger>(i);
            char const* name = tc::trigger_name(t);
            tc::Trigger back{};
            if (name == nullptr || !tc::trigger_from_name(name, back) || back != t)
                continue;
            out << (first ? "" : ",") << quote(name) << ":" << i;
            first = false;
        }
        // CostCount names in enum order: Condition::GAME_COUNT stores the enum as a number.
        out << "},\n\"costCounts\":[";
        for (int i = 0; i < 256; ++i)
        {
            tc::CostCount back{};
            std::string name = tc::cost_count_name(static_cast<tc::CostCount>(i));
            if (i == 0)
                name = "NONE";   // cost_count_name spells NONE as ""
            (void)back;
            if (name.empty())   // past the last member (some names are only GAME_COUNT's, not the loader's)
                break;
            out << (i ? "," : "") << quote(name);
        }
        out << "],\n\"kinds\":{";
        // Each ability lowered alone becomes a card of a scratch catalogue ("<id>#<n>"), so the
        // public programs.json writer encodes its effects exactly as the real data is encoded.
        tc::Catalogue scratch;
        first = true;
        for (tc::CardDef const* d : catalogue.all())
        {
            if (d == nullptr || !d->program || d->program_origin != tc::ProgramOrigin::GRAMMAR)
                continue;
            out << (first ? "\n" : ",\n") << quote(d->id) << ":[";
            for (std::size_t a = 0; a < d->program->abilities.size(); ++a)
            {
                tc::Program one;
                one.ir_version = 1;
                one.origin = tc::ProgramOrigin::GRAMMAR;
                one.abilities.push_back(d->program->abilities[a]);
                tc::LowerResult const lowered = tc::lower_program(one);
                out << (a ? "," : "") << (lowered.ok ? static_cast<int>(d->program->abilities[a].on.kind) : -1);
                tc::CardDef part;
                part.id = d->id + "#" + std::to_string(a);
                part.name = part.id;
                part.implemented = true;
                part.collectible = false;
                part.droppable = false;
                part.effects = lowered.effects;
                scratch.add(std::move(part));
            }
            out << "]";
            first = false;
        }
        out << "},\n\"lowered\":" << tc::programs_json(scratch, tc::kRulesVersion);
        out << "}\n";
        if (!out)
            return 1;
        if (dump_path.empty() && cards_path.empty())
            return 0;
    }

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
                    << ",\"races\":" << d->races << ",\"spellDamage\":" << d->spell_damage
                    << ",\"madeOnly\":" << (d->made_only ? "true" : "false")
                    << ",\"collectible\":" << (d->collectible ? "true" : "false")
                    << ",\"droppable\":" << (d->droppable ? "true" : "false")
                    << ",\"implemented\":" << (d->implemented ? "true" : "false")
                    << ",\"text\":" << quote(d->text);
                // Attributes the loader reads off printed reminders (not program data).
                if (!d->launch_upgrade.empty())
                    out << ",\"launchUpgrade\":" << quote(d->launch_upgrade);
                if (!d->next_drink.empty())
                    out << ",\"nextDrink\":" << quote(d->next_drink);
                if (!d->held_spell_transform.empty())
                    out << ",\"heldSpellTransform\":" << quote(d->held_spell_transform)
                        << ",\"heldSpellThreshold\":" << d->held_spell_threshold;
                if (d->repeat_next_school != tc::SpellSchool::NONE)
                    out << ",\"repeatNextSchool\":" << static_cast<int>(d->repeat_next_school);
                if (d->spellburst_kept_by != tc::SpellSchool::NONE)
                    out << ",\"spellburstKeptBy\":" << static_cast<int>(d->spellburst_kept_by);
                if (d->leaves_no_corpse)
                    out << ",\"leavesNoCorpse\":true";
                if (!d->choice_labels.empty())
                {
                    out << ",\"choiceLabels\":[";
                    for (std::size_t i = 0; i < d->choice_labels.size(); ++i)
                        out << (i ? "," : "") << quote(d->choice_labels[i]);
                    out << "]";
                }
                out << "}";
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
                if (!forced_family.empty())
                    for (tc::Family f : families)
                        if (forced_family == tc::family_name(f))
                            picked[seat] = f;
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

        // As the realm and jankcraft's own simulator do (tc/ai/sim.cpp): each seat plays its family's
        // class and hero power.
        engine->set_class(tc::Seat::A, picked[0]);
        engine->set_class(tc::Seat::B, picked[1]);
        engine->set_hero_power(tc::Seat::A, tc::TcEngine::hero_power_for(picked[0]));
        engine->set_hero_power(tc::Seat::B, tc::TcEngine::hero_power_for(picked[1]));

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
            int chosen = -1;
            for (std::size_t i = 0; i < moves.size() && chosen < 0; ++i)
                for (std::string const& name : prefer)
                    if (moves[i].action == "play" && moves[i].desc.rfind("Play " + name, 0) == 0)
                    {
                        chosen = static_cast<int>(i);
                        break;
                    }
            if (chosen < 0)
                chosen = choose(policy, moves);

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
