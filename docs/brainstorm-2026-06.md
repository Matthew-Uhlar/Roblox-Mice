# Source: Initial Brainstorming — Early June 2026 (Confluence export)

> Verbatim text of the team's brainstorm page, kept as the source spec. Interpretation lives in GDD.md.

The goal of this page is to list our ideas and thoughts on what we want our first game to be, what kind of development engine we want to use, and how that engine best facilitates our desired gameplay loops and systems. Nothing here is a final decision, but rather helps us get our foot in the door and get moving with early planning and prototyping.

Facilitator

Harrison Gerber

Participants

Devin Field

Matthew Uhlar

Gianclaudio Cordioli

Brainstorm dates

01 Jun 2026, 02 Jun 2026

On this page

- Brainstorming Items

- Summary of brainstorming items

- Action Items

 Brainstorming Items

Topic 1: Unity or Unreal

Notes from GPT

Direct comparison summary

Unity (for this game type)

Timeline:

Prototype: 2 to 3 months

Vertical slice: 5 to 6 months

Full game: 12 to 14 months

Strengths: fastest iteration speed best for gameplay heavy swarm systems easiest for small team productivity best asset pipeline leverage

Weakness: requires effort for AAA level visuals

Unreal (for this game type)

Timeline: Prototype: 3 to 4 months

Vertical slice: 6 to 8 months

Full game: 14 to 18 months

Strengths: highest visual ceiling better built in VFX and lighting strong for cinematic presentation

Weakness: slower gameplay iteration heavier system overhead for small teams Final answer For a 4 person indie team building a League style camera game with Vampire Survivors + Crab Champions gameplay:

Best overall outcome speed + quality balance → Unity

Best visual quality ceiling → Unreal

Best chance of finishing quickly → Unity

Do we want to use Unity or Unreal? Thoughts below:

- 
Harrison Gerber - Would like to use Unreal just to learn it despite additional possible complexity, but not tied down to this, especially for 1st game. Seems overall Unity would be the better option for what we are aiming to do here.

- 
Harrison Gerber - Networking could be a major consideration in this since we want this to be a co-op game; if one dev engine has significantly better networking capabilities than the other, that should be our highest priority choice to make the multiplayer experience as smooth as possible.

Topic 2: Main Gameplay Style

What type of game is this? Genre, style, etc? Thoughts below:

- 
Harrison Gerber - “RougePG-Like” - combination of RPG and Rougelike (don’t shit on me for this name it’s a placeholder alright”

Topic 3: Primary Gameplay Loop/Core Progression

What is the main loop going to look like? How does the user progress within runs and also within the larger game itself? Thoughts below:

- 
Harrison Gerber - Single map increased difficulty: check this image from Death Must Die; could be a useful consideration. This is for the first map called “Outer Circle”, once you beat it you can add these modifiers to it to increase difficulty and add additional rewards. We shouldn’t copy this, but it’s a thought on how to make increased difficulty within the same maps while still allowing player choice and risk v reward.

Topic 4: Main Multiplayer/Co-op Game Notes

- 
Harrison Gerber - from Caleb Crawford: try to avoid physics-based object interactions for this game; it’s possible but very difficult. Don’t make objects moving in a physical manner necessary or relevant to gameplay mechanics or interactions. Example - no making a shot body fall onto a button to open some door, the de-sync of this can be very tricky to manage for this first game.

Topic 5: In match dynamic player power

- 
Matthew Uhlar - Select levels similar to crab champions, each level shows two things with an option of three different levels each time. One is a negative modifier i.e. one shot, falling objects or fast enemies. The other is a buff for the entire group that lasts the rest of the run after defeating the boss of that map i.e. additional projectile, double/triple ability size or 50% ability CD. One option will be low reward, low penalty. One will be Mid and the other high.

Topic 6: Boss Selection

- 
Matthew Uhlar - Similar to transit mode in tarkov there are set bosses/maps and you select between a boss on the lowest difficult the three bosses will not have a downside. On higher difficulties there will be a downside lasting only that map and the highest difficulty lasting the entire run. Potential on highest difficulty for an option to cleanse one negative. No downside on first boss. Low chance to get an epic version of the drop

Topic 7: Classes, Maps, Bosses, and Events

Classes:

- 
Elephante

- 
Ele Fonte

- 
Ellie Fawn

- 
Le F’ante

- 
Filet

- 
Dumbo

- 
Fanta

Maps:

- 
Plains / Highlands

- 
Forest

- 
Jungle

- 
Beach / Islands (Sand is Parmesan Cheese)

- 
Tundra (Blue Cheese)

- 
Volcano (Cheddar Cheese)

- 
Toxic Swamp (Moldy Cheese)

- 
Space Moon (Mozzarella Cheese)

- 
Deep Ocean

Bosses:

- 
Giant Tree 

- 
Froggers (Frog that looks like Gragas, Frogas)

- 
Serpent Sisters (3)

- 
My Grandma

- 
Floating Witch (Rotating spells, gamba fight)

- 
Corndog Bunny

- 
Spider Machine (AI Spider that Adapts to Terrain)

- 
Green Gorilla

- 
Paper Dinosaur

- 
Dark Hematite Snake

- 
Ancient Ice Dragon

- 
Void Cat  

- 
Speedy Gonzalez?

Extra Notes

- 
Harrison Gerber - bonuses/abilities/upgrades need to feel meaningful; “1% boost to enemies at a far range while frozen” is kind of a dumb stat upgrade - it’s mostly meaningless in the vast majority of cases and provides such a small boost in those uncommon situations that it just shouldn’t be considered.

- 
Gianclaudio Cordioli ~

Game Start:
Round I

> Select Map/Terrain ~ 3 Options

> Random Boss

> Defeat Boss

> Select Reward ~ Map / Boss / Random
Round II

> Select Map Event Tier

> Random Map 

> Random Boss

> Defeat Boss

> Select Reward ~ Map / Boss / Random
Round III

> Select Map Event Tier

> Random Map

> Random Boss

> Defeat Boss

> Select Reward ~ Map / Boss / Random

> Double or Nothing? 1.5x/2x Multiplier to Rewards

- 
Harrison Gerber - Map Design concept: each map is NOT “procedurally generated” necessarily - it’s a pre-designed map with natural obstacles (rocks, trees, waterfalls, cliffsides, etc), but groups spawn in mostly random areas of the map, and each map has a lot of POI spawn locations and POIs can spawn randomly in each of those locations - that’s the “procedurally generated” aspect. Some pathways or areas may have unique POIs - may take a few runs to see them all guaranteed - not COMPLETELY RNG.

- 
Harrison Gerber Runs contain “cycles” - could be 4 maps per cycle; if we have 8 maps, this first cycle is guaranteed to contain no repeats, at the end of the cycle you get the choice to go home for free (where after each map in the cycle you can either 1. continue on, or 2. “double or nothing” it), and after beating a “cycle”, a new “cycle” begins with 4 random maps of the pool with no duplicates (but can duplicate from previous cycles).

Summary of brainstorming items

- 
General Roadmap Concept

- 
Each run moving between “maps/zones” as the player moves through them and defeats bosses and gets upgrades is one of the core tenants of the game. Game gets more difficult as you go into deeper and deeper zones, with unique modifiers/penalties occurring at random as you move through them, but with higher potential rewards as it goes.

- 
“Maps/Zones” should be able to moved to from one to the next in any order and have this movement feel like an impactful choice, and one where players are not limited, IE if you are in “Foothills”, you can only move to “Forest” or “Mountains” - why not let them move to “Beach” or “Deep Ocean” via a portal? Any one should transition to any other.

Character Theme

Elephant vs Mice

Action Items

- 
Harrison Gerber

- Make pages to facilitate discussion and design on:

- 
Progression mechanics

- 
In-run advancement

- 
World/Story/Lore

- 
Characters & Style

