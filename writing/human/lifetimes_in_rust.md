I would push back on the tests being hard to manage, the pattern of using Box::leak() in tests is fairly standard. My big question is how do you update the listeners at runtime if you arent doing something like this. I also would beg to differ that it makes things needlessly complicated. In my opinion there should be 3 kinds of data for lifetimes in multithreaded apps:
- Owned Data: Almost all variables, but also often in the form of messages being passed between threads. Putting these in an Arc, is bad form because an Arc or an Arc/RwLock in addition to incurring some performance overhead is a warning that the rest of the application is touching this data as you work on it, and can potentially change it as you work on it, and as such you need to worry about dealing with that class of bugs.
- Data that remains valid throughout the lifetime of the program: &'statics & OnceCells. The main reason why I personally dont like using Arc for this, is that it muddies the meaning behind what a "global variable" is. An Arc can get destroyed at anytime by any process, in fact this is exactly why you use an Arc, but in this sense using an Arc, for data that *you the programmer know* is going to last forever is robbing the lifetime system of any communicative value to you as a programmer. Plus its also inducing a bunch of runtime overhead, constantly incrementing and decrementing the count every time you copy a reference.
- Data that you have no clue where it belongs and how long its going to last: Arc

This probably seems weird coming from other languages and trying to standardize the idea of "best practices" and "DRY" to rust. Because oftentimes those patterns in other languages will make the entire application a total Arcfest. So is it better to try and adapt """best practices""" from other languages?

I think an answer to this can be found in this very strong Bob Harper quote/rant, in a lecture he was giving on HOTT:
> People often argue if Constructive or Classical mathematics is a better, but this isn't the right framing because Classical math is just a subset of constructive math. Just because any prop P is true classically if (X: Prop -> X \vee \neg X) -> P is true constructively. But in classical mathematics the only way to recover constructivity is to derive category theory from scratch, then spend an inordinate amount of effort constructing a grothendiek topos that reflect the axioms you want to study. The people defending classical mathematics are making the rather strong claim that all the extra information contained in constructive math has almost no value, which might even be defensible, but that's never how the conversation is framed. (Especially since most mathematicians seem to prefer direct proofs over double negation proofs.)

The same thing is true of the standard typing hierarchy in computing where you have this following relationship of subsets:

`Affine Types > Static Types > Dynamic Types`
 
As if you want python style syntax in rust, you can just declare every variable to be a Arc<Mutex<dyn Any>>, and when calling any method on it you can just unwrap() until you reach the root layer. (This is arguably what python already kind of ends up doing, which is why it ends up being so slow on application benchmarks.)

Importantly when I see an application that has a ton of Arc's everywhere, it's a sign to me that the application designer is either 1) trying to get things done quickly, or 2) isn't a huge fan of the affine types in rust, and might prefer if the entire thing was in a different programming language.  (But still might prefer rust for its combination of speed/safety)

Both of those might be perfectly defensible statements. But I would respond to them that the whole point of the affine type system is to add richness to the types of an application that don't exist with a normal type system.  And this richness forces you to think about how data flows through your application in a way you don't get with normal types, this is mostly sold on its ability to avoid certain classes of bugs memory safety or deadlocks, or its ability to model real world resources like a database connection more accurately.  But I think its main advantage is that it actually forces you to spend a lot more time thinking about how data flows through your program, and because you have to spend a lot more time thinking about it you are more likely to come up with better designs, and catch bugs manually that otherwise slip by you.

And secondarily if you are trying to get something done quickly, that makes it more imperative to deeply consider what you are doing not less, because the main goal when writing code isn't to get it done as fast as possible, its to save time debugging said code when the application doesnt work.  I also think this entire tradeoff is almost always misapplied, because its mistaking a tradeoff between correctness <-> speed, when its in fact a 3 way tradeoff between corectness <-> speed <-> complexity, and the biggest problem with codebases made by everyone (humans and LLM's both, but LLM's seem to suffer from it way more then humans in the present moment) (read: https://grugbrain.dev/). IMHO anything you can do to come to the sinking revalation that your code is way to complicated is a good thing. Because its always going to happen eventually, and its way better if that happens while you are writing it, then after building a ton of features and going through 6 months of debugging. This can take many forms, but just stripping out all the premature generalization and configuration can make the shape of the application a lot simpler, although the biggest gains are always going to come from pushing back against stupid requirements, and thinking of ways to rephrase the requirements so that your customers can get the same results with a simpler application.

### bUt wHaT aBoUt tEsTiNg???????

In general the point of writing tests is to reduce bugs in production, but they arent even the first or second line of defense to achive said goal. Reducing complexity in your code is the first, and the second is having code that is clear and easy to reason about. Therefore IMHO comprimising the readability and control flow of a program to wire in more tests (or even worse increasing architectural complexity to add tests) is an extremely bad idea.

I think the best way to design the application is to focus on making the application as simple as possible, then focus on implemenenting it in the most straightforward and clear way. Only then should you do whatever horrible thing must be done in the tests to make sure that you have adequate coverage. Also, the point of programming paradigms and best practices is to make sure your production code is easy to reason about and debug, however, in tests the main thing you have to worry about is subjecting your application to all the noise and random data that might get thrown its way by an average user. Dirtyness and messiness on this code path doesn't introduce any bugs or weird behavior in production.


# How do you actually implement this in real code?

Sometimes for networked applications you need to use network requests at the beginning of a program to set up things that are used for the rest of the program lifetime, but this can be handled quite well with

tokio::OnceCell,

and the following method:


Source
pub async fn get_or_try_init<E, F, Fut>(&self, f: F) -> Result<&T, E>
where
    F: FnOnce() -> Fut,
    Fut: Future<Output = Result<T, E>>,

Gets the value currently in the OnceCell, or initialize it with the given asynchronous operation.

If some other task is currently working on initializing the OnceCell, this call will wait for that other task to finish, then return the value that the other task produced.

If the provided operation returns an error, is cancelled or panics, the initialization attempt is cancelled. If there are other tasks waiting for the value to be initialized, one of them will start another attempt at initializing the value.

This will deadlock if f tries to initialize the cell recursively.





