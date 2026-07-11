managed implementation in class %%BEHAVIOR_CLASS%% unique;
%%STRICT%%
define behavior for %%ROOT_VIEW%% alias %%ALIAS%%
persistent table %%TABLE%%
lock master
authorization master ( instance )
{
  create;
  update;
  delete;

  field ( readonly ) %%KEY_ELEMENT%%;

  mapping for %%TABLE%%
  {
%%BDEF_MAPPING%%
  }
}
