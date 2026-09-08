# Open Images attribution

`FoodBroadIdentity.mlmodel` was trained from food-region crops derived from
[Open Images](https://storage.googleapis.com/openimages/web/factsfigures_v7.html).
The Open Images metadata used for this run marked the downloaded source images
as [CC BY 2.0](https://creativecommons.org/licenses/by/2.0/); the bounding-box
annotations are published under CC BY 4.0. The per-image source URL, creator,
and license record is retained in the generated `attribution.csv` files under
the local dataset workspace. Verify those records before redistributing any
source images or a derivative dataset.

The model is a broad visual food-family classifier, not a nutrition or medical
model. Its output is used only as a high-confidence correction to the bundled
on-device classifier.
