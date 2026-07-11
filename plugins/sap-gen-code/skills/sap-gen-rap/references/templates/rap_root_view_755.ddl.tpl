@AccessControl.authorizationCheck: #NOT_REQUIRED
@EndUserText.label: '%%LABEL%%'
@Metadata.allowExtensions: true
define root view entity %%ROOT_VIEW%%
  as select from %%TABLE%%
{
%%ROOT_FIELDS%%
}
