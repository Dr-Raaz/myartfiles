BEGIN;

INSERT INTO public.categories (id,name,description,icon,sort_order,is_active)
VALUES
('cat-animals','Animals','Cute, friendly animals and pets to color.','🐾',1,true),
('cat-flowers','Flowers','Blossoming flowers, pretty petals, and garden blooms.','🌸',2,true),
('cat-nature','Nature','Mountains, trees, sunny skies, and dinosaurs.','🌿',3,true),
('cat-vehicles','Road & Vehicles','Rockets, cars, trains, and speedy wheels.','🚀',4,true),
('cat-houses','Houses','Cozy cottages, fairy mushroom homes, and castles.','🏡',5,true),
('cat-birds','Birds','Chirping chicks, majestic owls, and flying friends.','🐦',6,true),
('cat-fruits','Fruits','Delicious apples, strawberries, and sweet bananas.','🍓',7,true),
('cat-sea','Sea Animals','Dolphins, starfish, friendly whales, and ocean fish.','🐬',8,true)
ON CONFLICT (id) DO NOTHING;

COMMIT;
